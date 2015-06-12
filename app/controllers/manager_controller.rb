ACCT_NAME = YAML.load_file("#{Rails.root}/config/canvas_spaces.yml")[Rails.env]['acct_name']
GROUP_CAT_NAME = YAML.load_file("#{Rails.root}/config/canvas_spaces.yml")[Rails.env]['group_cat_name']
GROUP_CATEGORY = GroupCategory.find_by_name(GROUP_CAT_NAME)
MAILLIST_TOKEN = YAML.load_file("#{Rails.root}/config/sfu.yml")['maillist_ckid_token']

require Pathname("#{Rails.root}/vendor/plugins/sfu_api/app/model/sfu/sfu")

require "rest-client"
require 'uri'

class ManagerController < ApplicationController
  before_filter :require_user

  SETTABLE_GROUP_ATTRIBUTES = %w(
    name description join_level leader
  ).freeze

  #
  # Render the entry point for the UI
  def index
  end

  #
  # Convert from internal value to user-friendly type used
  # by our API.
  #
  def display_join_type(join_level)
    case join_level
      when "invitation_only"
        "invite_only"
      when "parent_context_auto_join"
        "free_to_join"
      when "parent_context_request"
        "request"
      else
        "unknown:" + join_level
      end
  end

def convert_join_type_to_join_level(join_type)
  case join_type
    when 'invite_only'
      'invitation_only'
    when 'free_to_join'
      'parent_context_auto_join'
    when 'request'
      'parent_context_request'
    else
      "unknown #{join_level}"
    end
end

  #
  # List all groups in the special group set that belongs to the
  # special account.
  #
  def list_groups
    groups = GROUP_CATEGORY.groups.active.order(:name)
    # filter out non-public groups for non-admins
    groups = groups.where(join_level: 'parent_context_auto_join') unless @current_user.account.site_admin?
    groups_json = Api.paginate(groups, self, api_v1_canvasspaces_groups_url).map do |g|
      include = @current_user.account.site_admin? || @current_user.id == g.leader_id ? ['users'] : []
      group_formatter(g, { include: include })
    end
    render :json => groups_json
  end

  def list_groups_for_user
    user_id = params[:user_id] == 'self' ? @current_user.id : params[:user_id]

    unless user_id.to_i == @current_user.id || @current_user.account.site_admin?
      render_json_unauthorized
      return
    end

    groups = User.find(user_id).current_groups.where(group_category_id: GROUP_CATEGORY.id, workflow_state: 'available').order(:name)
    groups_json = Api.paginate(groups, self, api_v1_canvasspaces_user_groups_url).map do |g|
      include = @current_user.account.site_admin? || @current_user.id == g.leader_id ? ['users'] : []
      group_formatter(g, { include: include })
    end
    render :json => groups_json
  end

  #
  # Create a group.
  # If called by a non-admin user then the user will be made leader of the group.
  # Any specified leader is ignored.
  # If called by an admin a leader may be specified.
  # leader is canvas id
  # join_type is either: 'request', free_to_join' or 'invite_only'
  #
  def create_group
    acct = Account.find_by_name(ACCT_NAME)

    name_param = params[:name]
    description_param = params[:description]
    members_param = params[:members] || []
    maillists_param = params[:maillists] || []
    leader_id_param = params[:leader_id]
    join_type_param = params[:join_type]

    if name_param.nil? || name_param.blank?
      render json: { field: 'name', error: 'You must provide a name for your space' }, status: :bad_request
      return
    end

    unless group_name_is_unique? name_param
      render json: { field: 'name', error: "A Space named \"#{name_param}\" already exists" }, status: :bad_request
      return
    end

    if description_param.nil? || description_param.blank?
      render json: { field: 'description', error: 'No description specified' }, status: :bad_request
      return
    end

    if join_type_param.nil? || join_type_param.blank?
      render json: { field: 'join_type', error: 'No join_type specified' }, status: :bad_request
      return
    end

    # all users must be valid
    members = members_param.map do | member |
      pseudonym = user_for_sfu_username(member)
      if pseudonym.nil?
        render json: { field: 'members', error: "\"#{member}\" is not a valid Canvas user" }, status: :bad_request
        return
      end
      pseudonym.user
    end
    members.uniq!

    # all maillists must be valid
    maillists_param.each do | maillist |
      if (!maillist_is_valid? maillist)
        render json: { field: 'maillists', error: "\"#{maillist}\" is not a valid maillist" }, status: :bad_request
        return
      end
    end
    maillists_param.uniq!


    if @current_user.account.site_admin?
      if leader_id_param && !leader_id_param.blank?
        leader = User.find_by_id(leader_id_param)
        if leader.nil?
          render json: { error: "Can't find user specified for leader" }, status: :bad_request
          return
        end
      else
        leader = nil
      end
    else
      # if a non-admin is creating the group then
      # the leader is that user and that id is used to determine who "owns"
      # the group and can make changes to it
      leader = @current_user
    end

    if join_type_param == 'free_to_join'
      join_type = 'parent_context_auto_join'
    elsif join_type_param == 'request'
      join_type = 'parent_context_request'
    elsif join_type_param == 'invite_only'
      join_type = 'invitation_only'
    else
      render json: { field: 'join_type', error: 'Invalid join_type value. Valid: request, free_to_join, invite_only' }, status: :bad_request
      return
    end

    group = acct.groups.create( name: name_param,
                                group_category: GROUP_CATEGORY,
                                leader: leader,
                                join_level: join_type,
                                description: description_param )
    group.add_user(leader) if !leader.nil?
    group.save
    members.each { |member| group.add_user(member) } unless members.empty?

    render json: group.as_json(only: [ :id, :name, :description, :leader_id, :created_at ],
                               include_root: false)
                      .merge({ size: 0, join_type: join_type_param }), status: :ok
  end

  #
  # Return info on a group.
  # Anyone can access this information.
  #
  def group_info
    group_id_param = params[:group_id]

    if group_id_param.nil? || group_id_param.blank?
      render json: { error: 'group_id not specified.' }, status: :bad_request
      return
    end

    group = GROUP_CATEGORY
            .groups
            .where('groups.id = ?', group_id_param)
            .eager_load(:users)
            .first
    if group.nil?
      render json: { error: 'No such group found.' }, status: :not_found
    else
      render json: { id: group.id,
                     name: group.name,
                     description: group.description,
                     leader_id: group.leader_id,
                     created_at: group.created_at,
                     join_type: display_join_type(group.join_level),
                     size: group.users.count
                   },
             status: :ok
    end
  end

  #
  # Change group properties: description or join type.
  #
  def modify_group
    attrs = params
    group = Group.find_by_id attrs[:group_id]

    if attrs[:join_type]
      attrs[:join_level] = convert_join_type_to_join_level(attrs[:join_type])
    end

    if attrs[:leader_id] && attrs[:leader_id] != group.leader_id
      membership = group.group_memberships.where(user_id: attrs[:leader_id]).first
      return render :json => {}, :status => :bad_request unless membership
      attrs[:leader] = membership.user
    end

    if authorized_action(group, @current_user, :update)
      respond_to do |format|
        group.transaction do
          group.update_attributes(attrs.slice(*SETTABLE_GROUP_ATTRIBUTES))
        end

        if !group.errors.any?
          format.json { render :json => group_formatter(group), :status => :ok }
          # render json: group_formatter(group), status: :ok
        else
          format.json { render :json => @group.errors, :status => :bad_request }
        end
      end
    end
  end

  #
  # Delete the group.
  #
  def delete_group
    group_id_param = params[:group_id]

    if group_id_param.nil? || group_id_param.blank?
      render json: { error: 'group_id not specified.' }, status: :bad_request
      return
    end

    group = GROUP_CATEGORY.groups.where('groups.id = ?', group_id_param).first
    if group.nil?
      render json: { error: 'No such group found.' }, status: :not_found
    else
      if @current_user.account.site_admin? || group.leader_id == @current_user.id
        group.destroy
        render json: { message: "Group is destroyed." }, status: :ok
      else
        render json: { error: "Can't delete group. Not owner." }, status: :forbidden
      end
    end
  end

  #
  # List the users in the group as well as the number of users.
  #
  def list_users
    group_id_param = params[:group_id]

    if group_id_param.nil? || group_id_param.blank?
      render json: { error: 'group_id not specified.' }, status: :bad_request
      return
    end

    group = GROUP_CATEGORY.groups.find_by_id(group_id_param)
    if group.nil?
      render json: { error: 'No such group found.' }, status: :bad_request
    else
      if @current_user.account.site_admin? || group.leader_id == @current_user.id
        render json: { size: group.users.count, users: group.users.map { |user| user.as_json(only: [:id, :name], include_root: false) } }, status: :ok
      else
        # doesn't have access to the group
        render json: { error: "Can't list users. Not owner." }, status: :forbidden
      end
    end
  end

  #
  # Add user to a group.
  # The site admin can add any user to a group.
  # The leader of the group may add any user.
  # A user may add himself/herself to a group.
  # user = Canvas id of student
  # TODO: How is this affected by the join_level?
  #
  def add_user
    group_id_param = params[:group_id]
    user_id_param = params[:user_id]

    if group_id_param.nil? || group_id_param.blank?
      render json: { error: 'group_id not specified.' }, status: :bad_request
      return
    end

    if user_id_param.nil? || user_id_param.blank?
      render json: { error: 'user_id not specified.' }, status: :bad_request
      return
    end

    user = User.find_by_id(user_id_param)
    if user.nil?
      render json: { error: "Can't find user #{user_id_param}." }, status: :bad_request
      return
    end

    group = GROUP_CATEGORY.groups.find_by_id(group_id_param)
    if group.nil?
      render json: { error: 'No such group found.' }, status: :bad_request
    else
      if @current_user.account.site_admin? ||
         group.leader_id == @current_user.id ||
         @current_user.id == user.id

        group.add_user user
        group.save

        render json: { message: 'Successfully added user.' }, status: :ok
      else
        # doesn't have access to the group
        render json: { error: "Can't add user. Not owner or not adding self." }, status: :forbidden
      end
    end
  end

  #
  # Remove user from a group.
  # The site admin can remove any user from a group.
  # The leader of the group may remove any user.
  # A user may remove himself/herself to a group.
  # user_id = canvas id of user to remove
  # Can't remove user if he/she is the leader. Someone else must be made leader first.
  #
  def remove_user
    group_id_param = params[:group_id]
    user_id_param = params[:user_id]

    if group_id_param.nil? || group_id_param.blank?
      render json: { error: 'group_id not specified.' }, status: :bad_request
      return
    end

    if user_id_param.nil? || user_id_param.blank?
      render json: { error: 'user_id not specified.' }, status: :bad_request
      return
    end

    user = User.find_by_id(user_id_param)
    if user.nil?
      render json: { error: "Remove failed. Can't find user #{user_param}." }, status: :bad_request
      return
    end

    group = GROUP_CATEGORY.groups.find_by_id(group_id_param)
    if group.nil?
      render json: { error: 'No such group found.' }, status: :bad_request
    else
      if @current_user.account.site_admin? || group.leader_id == @current_user.id || @current_user.id == user.id
        if group.leader_id == user.id
          render json: { error: "Can't remove user that is the leader of the group." }, status: :bad_request
          return
        end

        membership = group.group_memberships.where(user_id: user).first
        membership.workflow_state = 'deleted'
        membership.save
        render json: { message: 'Successfully removed user.' }, status: :ok
      else
        # doesn't have access to the group
        render json: { error: "Can't remove user. Not owner or not adding self." }, status: :forbidden
      end
    end
  end

  #
  # Change leadership of the group.
  # Admin may set anyone as leader of the group.
  # Leader of the group may set anyone as leader of the group.
  # I don't check to see if the new leader is a member of the group.
  #
  def set_leader
    group_id_param = params[:group_id]
    leader_id_param = params[:leader_id]

    if leader_id_param.nil? || leader_id_param.blank?
      render json: { error: 'No leader_id supplied.' }, status: :bad_request
      return
    end

    # lookup canvas id by sfu-id
    leader = User.find_by_id(leader_id_param)
    if leader.nil?
      render json: { error: "Leader change failed. Can't find user #{leader_id_param}." }, status: :bad_request
      return
    end

    group = GROUP_CATEGORY.groups.find_by_id(group_id_param)
    if group.nil?
      render json: { error: 'No such group found.' }, status: :bad_request
    else
      if @current_user.account.site_admin? || group.leader_id == @current_user.id
        # New leader must be a member of the group.
        group.add_user(leader) # this call is idempotent so we can call it even if the user is already a member
        group.leader_id = leader.id
        group.save
        render json: { message: 'Successfully changed leader.' }, status: :ok
      else
        # doesn't have access to the group
        render json: { error: "Can't change leader. Not owner." }, status: :forbidden
      end
    end
  end

  #
  # Validate that a group name is unique
  #
  def validate_group_name
    group_name_param = params[:group_name]
    if group_name_is_unique?(group_name_param)
      render json: { valid_group_name: true }, status: :ok
    else
      render json: { valid_group_name: false,
                     message: "A Space named \"#{group_name_param}\" already exists"
                   },
             status: :ok
    end
  end

  #
  # Validate that a given SFU Computing ID or alias is valid
  # without leaking any other information about the user
  #
  def validate_sfu_user
    sfu_username = URI.unescape(params[:username])
    invalid_user_response = { valid_user: false }
    render json: { valid_user: sfu_user_is_valid?(sfu_username) }, status: :ok
  end

  #
  # Validate that a given SFU Maillist name is valid
  #
  def validate_maillist
    listname = params[:maillist]
    render json: { valid_maillist: maillist_is_valid?(listname) }, status: :ok
  end

  #
  # Test method.
  # Returns a list of all the users in the db.
  #
  def test_get_user_list
    if Rails.env.development?
      render json: User.all.map { |user| user.as_json(only: [:id, :name], include_root: false) }
    end
  end

  private

  def user_for_sfu_username(sfu_username)
    info = SFU::User.info sfu_username
    begin
      sfuid = info['sfuid']
    rescue
     return nil
    end
    Pseudonym.find_by_sis_user_id(sfuid)
  end

  def group_name_is_unique?(name)
    GROUP_CATEGORY.groups.first(conditions: [ "lower(name) = ? AND workflow_state != ?", name.downcase, 'deleted' ]).nil?
  end

  def sfu_user_is_valid?(sfu_username)
    return !user_for_sfu_username(sfu_username).nil?
  end

  def maillist_is_valid?(maillist)
    rest_url = "https://rest.maillist.sfu.ca/maillists?sfu_token=#{MAILLIST_TOKEN}&name=#{maillist}"
    # TODO: remove SSL verify none when fixed
    client = RestClient::Resource.new(rest_url, :verify_ssl => OpenSSL::SSL::VERIFY_NONE)
    client.get do | response, request, result |
      return response.code == 200 ? true : false
    end
  end

  def group_formatter(group, options = {})
    includes = options[:include] || []
    image = group.avatar_attachment
    avatar_url = image && image.thumbnail_url
    users = []
    if includes.include?('users')
      users = group.users.map{ |u| user_json(u, @current_user, session) }
    end

    group.as_json(only: [:id, :name, :created_at, :description, :leader_id], include_root: false).merge({
      member_count: group.users.count,
      join_type: display_join_type(group.join_level),
      is_leader: group.leader_id == @current_user.id,
      avatar_url: avatar_url,
      users: users
    })
  end

end
