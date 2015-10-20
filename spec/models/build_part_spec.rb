require 'spec_helper'

describe BuildPart do
  let(:repository) { FactoryGirl.create(:repository) }
  let(:branch) { FactoryGirl.create(:branch, :repository => repository) }
  let(:build) { FactoryGirl.create(:build, :branch_record => branch) }
  let(:build_part) { FactoryGirl.create(:build_part, :paths => ["a", "b"], :kind => "spec", :build_instance => build, :queue => 'ci') }

  before do
    allow(GitRepo).to receive(:load_kochiku_yml).and_return(nil)
  end

  describe "#create_and_enqueue_new_build_attempt!" do
    it "should create a new build attempt" do
      expect {
        build_part.create_and_enqueue_new_build_attempt!
      }.to change(build_part.build_attempts, :count).by(1)
    end

    it "updates the build state to running" do
      expect(build.state).not_to eq(:running)
      build_part.create_and_enqueue_new_build_attempt!
      expect(build.state).to eq(:running)
    end

    it "enqueues onto the queue specified in the build part" do
      build_part.update_attribute(:queue, 'queueX')
      expect(BuildAttemptJob).to receive(:enqueue_on).once do |queue, arg_hash|
        expect(queue).to eq("queueX")
      end
      build_part.create_and_enqueue_new_build_attempt!
    end

    it "should enqueue the build attempt for building" do
      build_part.update_attributes!(:options => {"ruby" => "ree"})
      expect(BuildAttemptJob).to receive(:enqueue_on).once do |queue, arg_hash|
        expect(queue).to eq("ci")
        expect(arg_hash["build_attempt_id"]).not_to be_blank
        expect(arg_hash["build_ref"]).not_to be_blank
        expect(arg_hash["build_kind"]).not_to be_blank
        expect(arg_hash["test_files"]).not_to be_blank
        expect(arg_hash["repo_name"]).not_to be_blank
        expect(arg_hash["test_command"]).not_to be_blank
        expect(arg_hash["repo_url"]).not_to be_blank
        expect(arg_hash["options"]).to eq({"ruby" => "ree"})
        expect(arg_hash["kochiku_env"]).to eq("test")
      end
      build_part.create_and_enqueue_new_build_attempt!
    end
  end

  describe "#job_args" do
    let(:repository) { FactoryGirl.create(:repository, :url => "git@github.com:org/test-repo.git") }

    context "with a git mirror specified" do
      before do
        settings = SettingsAccessor.new(<<-YAML)
        git_servers:
          github.com:
            type: github
            mirror: "git://git-mirror.example.com/"
        YAML
        stub_const "Settings", settings
      end

      it "should substitute the mirror" do
        build_attempt = build_part.build_attempts.create!(:state => :runnable)
        args = build_part.job_args(build_attempt)
        expect(args["repo_url"]).to eq("git://git-mirror.example.com/org/test-repo.git")
      end
    end

    context "with no git mirror specified" do
      before do
        settings = SettingsAccessor.new(<<-YAML)
        git_servers:
          github.com:
            type: github
        YAML
        stub_const "Settings", settings
      end

      it "should return the original git url" do
        build_attempt = build_part.build_attempts.create!(:state => :runnable)
        args = build_part.job_args(build_attempt)
        expect(args["repo_url"]).to eq(repository.url)
      end
    end
  end

  describe "#unsuccessful?" do
    subject { build_part.unsuccessful? }

    context "with all successful attempts" do
      before do
        2.times { FactoryGirl.create(:build_attempt, :build_part => build_part, :state => :passed) }
      end

      it { should be false }
    end

    context "with one successful attempt" do
      before {
        2.times { FactoryGirl.create(:build_attempt, :build_part => build_part, :state => :failed) }
        FactoryGirl.create(:build_attempt, :build_part => build_part, :state => :passed)
      }

      it { should be false }
    end

    context "with all unsuccessful attempts" do
      before do
        2.times { FactoryGirl.create(:build_attempt, :build_part => build_part, :state => :failed) }
      end

      it { should be true }
    end
  end

  describe "#status" do
    subject { build_part.status }

    context "with all successful attempts" do
      before do
        2.times { FactoryGirl.create(:build_attempt, :build_part => build_part, :state => :passed) }
      end

      it { should == :passed }
    end

    context "with one successful attempt" do
      before do
        FactoryGirl.create(:build_attempt, :build_part => build_part, :state => :failed)
        FactoryGirl.create(:build_attempt, :build_part => build_part, :state => :passed)
        FactoryGirl.create(:build_attempt, :build_part => build_part, :state => :failed)
      end

      it { should == :passed }
    end

    context "with no successful attempts" do
      before do
        FactoryGirl.create(:build_attempt, :build_part => build_part, :state => :failed)
        FactoryGirl.create(:build_attempt, :build_part => build_part, :state => :running)
      end

      it { should == :running }
    end
  end

  describe "#not_finished?" do
    subject { build_part.not_finished? }
    context "when not finished" do
      it { should be true }
    end
    context "when finished" do
      before { FactoryGirl.create(:build_attempt, :build_part => build_part, :state => :passed, :finished_at => Time.now) }
      it { should be false }
    end
  end

  describe "#last_junit_artifact" do
    let(:artifact) { FactoryGirl.create(:build_artifact, :log_file => File.open(FIXTURE_PATH + "rspec.xml.log.gz")) }
    let(:part) { artifact.build_attempt.build_part }

    subject { part.last_junit_artifact }

    it { should == artifact }

    describe "#last_junit_failures" do
      subject { part.last_junit_failures }

      it { should have(1).testcase }
    end
  end

  describe "#should_reattempt?" do
    let(:build_part) { FactoryGirl.create(:build_part, retry_count: 1, build_instance: build) }

    it "should reattempt" do
      expect(build_part.should_reattempt?).to be true
    end

    context "when we have already hit the retry count" do
      before do
        FactoryGirl.create(:build_attempt, build_part: build_part, state: :failed)
        FactoryGirl.create(:build_attempt, build_part: build_part, state: :failed)
      end

      it "will not reattempt" do
        expect(build_part.should_reattempt?).to be false
      end
    end

    context "when we are just one away from the retry count" do
      before do
        FactoryGirl.create(:build_attempt, build_part: build_part, state: :failed)
      end

      it "will reattempt" do
        expect(build_part.should_reattempt?).to be true
      end
    end

    context "when it fails very fast" do
      let(:build_part) { FactoryGirl.create(:build_part, retry_count: 0, build_instance: build) }

      before do
        FactoryGirl.create(:build_attempt, build_part: build_part, state: :errored, started_at: 10.seconds.ago, finished_at: Time.now)
      end

      it "will reattempt" do
        expect(build_part.should_reattempt?).to be true
      end
    end

    context "after 5 failures" do
      let(:build_part) { FactoryGirl.create(:build_part, retry_count: 0, build_instance: build) }

      before do
        5.times do
          FactoryGirl.create(:build_attempt, build_part: build_part, state: :errored, started_at: 10.seconds.ago, finished_at: Time.now)
        end
      end

      it "not will reattempt" do
        expect(build_part.should_reattempt?).to be false
      end
    end

    context "when it fails after a longer time" do
      let(:build_part) { FactoryGirl.create(:build_part, retry_count: 0, build_instance: build) }

      before do
        FactoryGirl.create(:build_attempt, build_part: build_part, state: :errored, started_at: 70.seconds.ago, finished_at: Time.now)
      end

      it "shouldn't reattempt" do
        expect(build_part.should_reattempt?).to be false
      end
    end
  end
end
