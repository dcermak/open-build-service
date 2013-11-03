require 'base64'

class Webui::RequestController < Webui::WebuiController
  include Webui::WebuiHelper
  include HasComments

  before_filter :require_login, :only => [:save_comment]

  def add_reviewer_dialog
    @request_id = params[:id]
    render_dialog 'requestAddReviewAutocomplete'
  end

  def add_reviewer
    required_parameters :review_type
    begin
      opts = {}
      case params[:review_type]
        when 'user' then
          opts[:user] = params[:review_user]
        when 'group' then
          opts[:group] = params[:review_group]
        when 'project' then
          opts[:project] = params[:review_project]
        when 'package' then
          opts[:project] = params[:review_project]
          opts[:package] = params[:review_package]
      end
      opts[:comment] = params[:review_comment] if params[:review_comment]

      Webui::BsRequest.addReview(params[:id], opts)
    rescue Webui::BsRequest::ModifyError
      flash[:error] = "Unable add review to '#{params[:id]}'"
    end
    redirect_to :controller => :request, :action => 'show', :id => params[:id]
  end

  def modify_review
    opts = {}
    params.each do |key, value|
      opts[:new_review_state] = 'accepted' if key == 'accepted'
      opts[:new_review_state] = 'declined' if key == 'declined'

      # Our views are valid XHTML. So, several forms 'POST'-ing to the same action have different
      # HTML ids. Thus we have to parse 'params' a bit:
      opts[:comment] = value if key.starts_with?('review_comment_')
      opts[:id] = value if key.starts_with?('review_request_id_')
      opts[:user] = value if key.starts_with?('review_by_user_')
      opts[:group] = value if key.starts_with?('review_by_group_')
      opts[:project] = value if key.starts_with?('review_by_project_')
      opts[:package] = value if key.starts_with?('review_by_package_')
    end

    begin
      Webui::BsRequest.modifyReview(opts[:id], opts[:new_review_state], opts)
    rescue Webui::BsRequest::ModifyError => e
      flash[:error] = e.message
    end
    redirect_to :action => 'show', :id => opts[:id]
  end

  def show
    redirect_back_or_to :controller => 'home', :action => 'requests' and return if !params[:id]
    begin
      @req = ::BsRequest.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      flash[:error] = "Can't find request #{params[:id]}"
      redirect_back_or_to :controller => 'home', :action => 'requests' and return
    end

    @req = @req.webui_infos
    @id = @req['id']
    @state = @req['state'].to_s
    @accept_at = @req['accept_at']
    @req['creator'] = User.find_by_login! @req['creator']
    @is_author = @req['creator'] == User.current
    @superseded_by = @req['superseded_by']
    @is_target_maintainer = @req['is_target_maintainer']

    @my_open_reviews = @req['my_open_reviews']
    @other_open_reviews = @req['other_open_reviews']
    @can_add_reviews = ['new', 'review'].include?(@state) && (@is_author || @is_target_maintainer || @my_open_reviews.length > 0) && !User.current.is_nobody?
    @can_handle_request = ['new', 'review', 'declined'].include?(@state) && (@is_target_maintainer || @is_author) && !User.current.is_nobody?

    @events = @req['events']
    @actions = @req['actions']

    request_list = session[:requests]
    @request_before = nil
    @request_after = nil
    index = request_list.index(@id) if request_list
    if index and index > 0
      @request_before = request_list[index-1]
    end
    if index
      # will be nul for after end
      @request_after = request_list[index+1]
    end

    sort_comments(::BsRequest.find(params[:id]).comments)
  end

  def sourcediff
    check_ajax
    render :partial => 'shared/editor', :locals => {:text => params[:text], :mode => 'diff', :read_only => true, :height => 'auto', :width => '750px', :no_border => true, uid: params[:uid]}
  end

  def changerequest
    required_parameters :id
    @req = Webui::BsRequest.find params[:id]
    unless @req
      flash[:error] = "Can't find request #{params[:id]}"
      redirect_back_or_to :controller => 'home', :action => 'requests' and return
    end

    changestate = nil
    ['accepted', 'declined', 'revoked', 'new'].each do |s|
      if params.has_key? s
        changestate = s
        break
      end
    end

    if change_request(changestate, params)
      # TODO: Make this work for each submit action individually
      if params[:add_submitter_as_maintainer_0]
        if changestate != 'accepted'
          flash[:error] = 'Will not add maintainer for not accepted requests'
        else
          tprj, tpkg = params[:add_submitter_as_maintainer_0].split('_#_') # split into project and package
          if tpkg
            target = Package.find(tpkg, :project => tprj)
          else
            target = WebuiProject.find(tprj)
          end
          target.add_person(:userid => @req.creator, :role => 'maintainer')
          target.save
        end
      end
    end

    accept_request if changestate == 'accepted'

    redirect_to :action => 'show', :id => params[:id]
  end

  def accept_request
    flash[:notice] = "Request #{params[:id]} accepted"

    # Check if we have to forward this request to other projects / packages
    params.keys.grep(/^forward_.*/).each do |fwd|
      forward_request_to(fwd)
    end

    # Cleanup prj/pkg cache after auto-removal of source projects / packages (mostly from branches).
    # To keep things simple, we don't check if the src prj had more pkgs, etc..
    @req.each_action do |action|
      if action.value('type') == 'submit' and action.has_element?('options') and action.options.value('sourceupdate') == 'cleanup'
        Rails.cache.delete("#{action.source.project}_packages_mainpage")
        Rails.cache.delete("#{action.source.project}_problem_packages")
      end
    end
  end

  def forward_request_to(fwd)
    tgt_prj, tgt_pkg = params[fwd].split('_#_') # split off 'forward_' and split into project and package
    description = @req.description.text
    if @req.has_element? 'state'
      who = @req.state.value('who')
      description += ' (forwarded request %d from %s)' % [params[:id], who]
    end

    rev = Package.dir_hash(@req.action.target.project, @req.action.target.package)['rev']
    req = Webui::BsRequest.new(:type => 'submit', :targetproject => tgt_prj, :targetpackage => tgt_pkg,
                               :project => @req.action.target.project, :package => @req.action.target.package,
                               :rev => rev, :description => description)
    req.save(:create => true)
    Rails.cache.delete('requests_new')
                                                # link_to isn't available here, so we have to write some HTML. Uses url_for to not hardcode URLs.
    flash[:notice] += " and forwarded to <a href='#{url_for(:controller => 'package', :action => 'show', :project => tgt_prj, :package => tgt_pkg)}'>#{tgt_prj} / #{tgt_pkg}</a> (request <a href='#{url_for(:action => 'show', :id => req.value('id'))}'>#{req.value('id')}</a>)"
  end

  def diff
    # just for compatibility. OBS 1.X used this route for show
    redirect_to :action => :show, :id => params[:id]
  end

  def list
    redirect_to :controller => :home, :action => :requests and return unless request.xhr? # non ajax request
    requests = Webui::BsRequest.list_ids(params)
    elide_len = 44
    elide_len = params[:elide_len].to_i if params[:elide_len]
    session[:requests] = requests
    requests = BsRequestCollection.new(ids: session[:requests]).relation
    render :partial => 'shared/requests', :locals => {:requests => requests, :elide_len => elide_len, :no_target => params[:no_target]}
  end

  def list_small
    redirect_to :controller => :home, :action => :requests and return unless request.xhr? # non ajax request
    requests = Webui::BsRequest.list(params)
    render :partial => 'shared/requests_small', :locals => {:requests => requests}
  end

  def delete_request_dialog
    @project = params[:project]
    @package = params[:package] if params[:package]
    render_dialog
  end

  def delete_request
    required_parameters :project
    begin
      req = Webui::BsRequest.new(:type => 'delete', :targetproject => params[:project], :targetpackage => params[:package], :description => params[:description])
      req.save(:create => true)
      Rails.cache.delete 'requests_new'
    rescue ActiveXML::Transport::Error => e
      flash[:error] = e.summary
      redirect_to :controller => :package, :action => :show, :package => params[:package], :project => params[:project] and return if params[:package]
      redirect_to :controller => :project, :action => :show, :project => params[:project] and return
    end
    redirect_to :controller => :request, :action => :show, :id => req.value('id')
  end

  def add_role_request_dialog
    @project = params[:project]
    @package = params[:package] if params[:package]
    render_dialog
  end

  def add_role_request
    required_parameters :project, :role, :user
    begin
      req = Webui::BsRequest.new(:type => 'add_role', :targetproject => params[:project], :targetpackage => params[:package], :role => params[:role], :person => params[:user], :description => params[:description])
      req.save(:create => true)
      Rails.cache.delete 'requests_new'
    rescue ActiveXML::Transport::NotFoundError => e
      flash[:error] = e.summary
      redirect_to :controller => :package, :action => :show, :package => params[:package], :project => params[:project] and return if params[:package]
      redirect_to :controller => :project, :action => :show, :project => params[:project] and return
    end
    redirect_to :controller => :request, :action => :show, :id => req.value('id')
  end

  def set_bugowner_request_dialog
    render_dialog
  end

  def set_bugowner_request
    required_parameters :project, :user, :group
    begin
      if params[:group] == 'False'
        req = Webui::BsRequest.new(:type => 'set_bugowner', :targetproject => params[:project], :targetpackage => params[:package],
                                   :person => params[:user], :description => params[:description])
      end
      if params[:user] == 'False'
        req = Webui::BsRequest.new(:type => 'set_bugowner', :targetproject => params[:project], :targetpackage => params[:package],
                                   :group => params[:group], :description => params[:description])
      end
      req.save(:create => true)
      Rails.cache.delete 'requests_new'
    rescue ActiveXML::Transport::NotFoundError => e
      flash[:error] = e.summary
      redirect_to :controller => :package, :action => :show, :package => params[:package], :project => params[:project] and return if params[:package]
      redirect_to :controller => :project, :action => :show, :project => params[:project] and return
    end
    redirect_to :controller => :request, :action => :show, :id => req.value('id')
  end

  def change_devel_request_dialog
    required_parameters :package, :project
    @project = WebuiProject.find params[:project]
    @package = WebuiPackage.find(params[:package], :project => params[:project])
    if @package.has_element?(:devel)
      @current_devel_package = @package.devel.value('package') || @package.value('name')
      @current_devel_project = @package.devel.value('project')
    end
    render_dialog
  end

  def change_devel_request
    required_parameters :devel_project, :package, :project
    begin
      req = Webui::BsRequest.new(:type => 'change_devel', :project => params[:devel_project], :package => params[:package], :targetproject => params[:project], :targetpackage => params[:package], :description => params[:description])
      req.save(:create => true)
      Rails.cache.delete 'requests_new'
    rescue ActiveXML::Transport::NotFoundError => e
      flash[:error] = e.summary
      redirect_to :controller => 'package', :action => 'show', :project => params[:project], :package => params[:package] and return
    end
    redirect_to :controller => 'request', :action => 'show', :id => req.value('id')
  end

  def set_incident_dialog
    render_dialog
  end

  def set_incident
    begin
      Webui::BsRequest.set_incident(params[:id], params[:incident_project])
      flash[:notice] = "Set target of request #{params[:id]} to incident #{params[:incident_project]}"
    rescue Webui::BsRequest::ModifyError => e
      flash[:error] = "Incident #{e.message} does not exist"
    end
    redirect_to :controller => :request, :action => 'show', :id => params[:id]
  end

  # used by mixins
  def main_object
    Webui::BsRequest.find params[:id]
  end

  private

  def change_request(changestate, params)
    begin
      if Webui::BsRequest.modify(params[:id], changestate, :reason => params[:reason], :force => true)
        flash[:notice] = "Request #{changestate}!"
        return true
      else
        flash[:error] = "Can't change request to #{changestate}!"
      end
    rescue Webui::BsRequest::ModifyError => e
      flash[:error] = e.message
    end
    return false
  end

end
