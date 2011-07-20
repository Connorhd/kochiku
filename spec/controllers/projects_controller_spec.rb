require 'spec_helper'
require 'rexml/document'

describe ProjectsController do
  describe "#show" do
    render_views

    before do
      @project = projects(:big_rails_app)
      @build1 = Build.create!(:queue => 'master', :state => :succeeded, :sha => 'abc', :project => @project)
      @build2 = Build.create!(:queue => 'master', :state => :error, :sha => 'def', :project => @project)
    end

    it "should return an rss feed of builds" do
      get :show, :id => @project.to_param, :format => :rss
      doc = REXML::Document.new(response.body)
      items = doc.elements.to_a("//channel/item")
      items.length.should == Build.count
      items.first.elements.to_a("title").first.text.should == "Build Number #{@build2.id} failed"
      items.last.elements.to_a("title").first.text.should == "Build Number #{@build1.id} success"
    end
  end

  describe "#status_report" do
    render_views
    before do
      @project = projects(:big_rails_app)
    end

    context "when a project has no builds" do
      before { @project.builds.should be_empty }

      it "should return 'Unknown' for activity" do
        get :status_report, :format => :xml
        doc = Nokogiri::XML(response.body)
        element = doc.at_xpath("/Projects/Project[@name='#{@project.name_with_branch}']")

        element['activity'].should == 'Unknown'
      end
    end

    context "with a in-progress build" do
      before do
        @project.builds.create!(:queue => 'master', :state => :running, :sha => 'abc')
      end

      it "should return 'Building' for activity" do
        get :status_report, :format => :xml
        doc = Nokogiri::XML(response.body)
        element = doc.at_xpath("/Projects/Project[@name='#{@project.name_with_branch}']")

        element['activity'].should == 'Building'
      end
    end

    context "with a completed build" do
      before do
        @project.builds.create!(:queue => 'master', :state => :failed, :sha => 'abc')
      end

      it "should return 'CheckingModifications' for activity" do
        get :status_report, :format => :xml
        doc = Nokogiri::XML(response.body)
        element = doc.at_xpath("/Projects/Project[@name='#{@project.name_with_branch}']")

        element['activity'].should == 'CheckingModifications'
      end
    end
  end

end