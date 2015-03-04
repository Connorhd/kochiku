class ProjectsController < ApplicationController
  caches_action :show, :cache_path => proc { |c|
    updated_at = Project.where(:name => params[:id]).select(:updated_at).first!.updated_at
    { :modified => updated_at.to_i }
  }

  def index
    @projects = Project.order("name ASC").decorate
  end

  def ci_projects
    @repositories = Repository.select(:name)
    @projects = Project.
      includes(:repository).
      order("name ASC").
      where(:name => @repositories.map(&:name)).decorate
  end

  def show
    @project = Project.find_by_name!(params[:id])
    @build = @project.builds.build
    @builds = @project.builds.includes(build_parts: :build_attempts).last(12)
    @current_build = @builds.last

    @build_parts = Hash.new
    @builds.reverse_each do |build|
      build.build_parts.each do |build_part|
        key = [build_part.paths.first, build_part.kind, build_part.options['ruby']]
        (@build_parts[key] ||= Hash.new)[build] = build_part
      end
    end

    if params[:format] == 'rss'
      # remove recent builds that are pending or in progress (cimonitor expects this)
      @builds = @builds.drop_while {|build| [:partitioning, :runnable, :running].include?(build.state) }
    end

    @project = @project.decorate

    respond_to do |format|
      format.html
      format.rss { @builds = @builds.reverse } # most recent first
    end
  end

  def health
    project = Project.find_by_name!(params[:id])
    @builds = project.builds.includes(:build_parts => :build_attempts).last(params[:count] || 12) # Get this from a param

    build_part_attempts = Hash.new(0)
    build_part_failures = Hash.new(0)
    failed_parts = Hash.new
    @builds.each do |build|
      build.build_parts.each do |build_part|
        key = [build_part.paths.sort, build_part.kind]
        build_part.build_attempts.each do |build_attempt|
          if build_attempt.successful?
            build_part_attempts[key] = build_part_attempts[key] + 1
          elsif build_attempt.unsuccessful?
            build_part_attempts[key] = build_part_attempts[key] + 1
            build_part_failures[key] = build_part_failures[key] + 1
            failed_parts[key] = (failed_parts[key] || []) << build_part
          end
        end
      end
    end

    @part_climate = Hash.new
    failed_parts.each do |key,parts|
      part_error_rate = (build_part_failures[key] * 100 / build_part_attempts[key])
      @part_climate[[part_error_rate, key]] = parts.uniq
    end

    @project = project.decorate
  end

  def build_time_history
    @project = Project.find_by_name!(params[:project_id])

    history_json = Rails.cache.fetch("build-time-history-#{@project.id}-#{@project.updated_at}") do
      @project.decorate.build_time_history.to_json
    end

    respond_to do |format|
      format.json do
        render :json => history_json
      end
    end
  end

  # GET /XmlStatusReport.aspx
  #
  # This action returns the current build status for all of the main projects in the system
  def status_report
    @projects = Repository.all.map { |repo|
      Project.where(:repository_id => repo.id, :name => repo.name).first.decorate
    }.compact
  end
end
