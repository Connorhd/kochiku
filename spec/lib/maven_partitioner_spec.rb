require 'spec_helper'

describe MavenPartitioner do
  subject { MavenPartitioner.new }

  describe "#incremental_partitions" do
    context "on master as the main build for the project" do
      let(:repository) { FactoryGirl.create(:repository) }
      let(:project) { FactoryGirl.create(:project, :name => repository.repository_name) }
      let(:build) { FactoryGirl.create(:build, :queue => :developer, :project => project, :branch => "master") }

      it "should be the main build" do
        build.project.should be_main_build
      end

      it "should return the set of modules to build for a given set of file changes" do
        GitBlame.stub(:files_changed_since_last_green).with(build).and_return(["module-one/src/main/java/com/squareup/foo.java",
                                                                               "module-two/src/main/java/com/squareup/bar.java"])
        File.stub(:exists?).and_return(false)
        File.stub(:exists?).with("module-one/pom.xml").and_return(true)
        File.stub(:exists?).with("module-two/pom.xml").and_return(true)

        subject.stub(:depends_on_map).and_return({
                                                     "module-one" => ["module-three", "module-four"].to_set,
                                                     "module-two" => ["module-three"].to_set
                                                 })
        subject.should_not_receive(:partitions)

        partitions = subject.incremental_partitions(build)
        partitions.size.should == 2
        if partitions[0]["files"][0] == "module-three"
          partitions[1]["files"][0].should == "module-four"
        else
          partitions[0]["files"][0].should == "module-four"
          partitions[1]["files"][0].should == "module-three"
        end
      end

      it "should build everything if one of the files does not map to a module" do
        GitBlame.stub(:files_changed_since_last_green).with(build).and_return(["toplevel/foo.xml"])

        subject.stub(:depends_on_map).and_return({
                                                     "module-one" => ["module-three", "module-four"].to_set,
                                                     "module-two" => ["module-three"].to_set
                                                 })

        subject.should_receive(:partitions).and_return([{"type" => "maven", "files" => "ALL"}])

        partitions = subject.incremental_partitions(build)
        partitions.first["files"].should == "ALL"
      end

      it "should not fail if a file is reference in a top level module that is not in the top level pom" do
        GitBlame.stub(:files_changed_since_last_green).with(build).and_return(["new-module/src/main/java/com/squareup/foo.java"])

        File.stub(:exists?).and_return(false)
        File.stub(:exists?).with("new-module/pom.xml").and_return(true)

        subject.stub(:depends_on_map).and_return({
                                                     "module-one" => ["module-three", "module-four"].to_set,
                                                     "module-two" => ["module-three"].to_set
                                                 })
        subject.should_not_receive(:partitions)

        partitions = subject.incremental_partitions(build)
        partitions.should be_empty
      end
    end

    context "on a branch" do
      let(:build) { FactoryGirl.create(:build, :queue => :developer, :branch => "branch-of-master") }

      it "should not be the main build" do
        build.project.should_not be_main_build
      end

      it "should return the set of modules to build for a given set of file changes" do
        GitBlame.stub(:files_changed_in_branch).with(build).and_return(["module-one/src/main/java/com/squareup/foo.java",
                                                                        "module-two/src/main/java/com/squareup/bar.java"])
        File.stub(:exists?).and_return(false)
        File.stub(:exists?).with("module-one/pom.xml").and_return(true)
        File.stub(:exists?).with("module-two/pom.xml").and_return(true)

        subject.stub(:depends_on_map).and_return({
                                                     "module-one" => ["module-three", "module-four"].to_set,
                                                     "module-two" => ["module-three"].to_set
                                                 })
        subject.should_not_receive(:partitions)

        partitions = subject.incremental_partitions(build)
        partitions.size.should == 2
        if partitions[0]["files"][0] == "module-three"
          partitions[1]["files"][0].should == "module-four"
        else
          partitions[0]["files"][0].should == "module-four"
          partitions[1]["files"][0].should == "module-three"
        end
      end

      it "should build everything if one of the files does not map to a module" do
        GitBlame.stub(:files_changed_in_branch).with(build).and_return(["toplevel/foo.xml"])

        subject.stub(:depends_on_map).and_return({
                                                     "module-one" => ["module-three", "module-four"].to_set,
                                                     "module-two" => ["module-three"].to_set
                                                 })

        subject.should_receive(:partitions).and_return([{"type" => "maven", "files" => "ALL"}])

        partitions = subject.incremental_partitions(build)
        partitions.first["files"].should == "ALL"
      end

      it "should not fail if a file is reference in a top level module that is not in the top level pom" do
        GitBlame.stub(:files_changed_in_branch).with(build).and_return(["new-module/src/main/java/com/squareup/foo.java"])

        File.stub(:exists?).and_return(false)
        File.stub(:exists?).with("new-module/pom.xml").and_return(true)

        subject.stub(:depends_on_map).and_return({
                                                     "module-one" => ["module-three", "module-four"].to_set,
                                                     "module-two" => ["module-three"].to_set
                                                 })
        subject.should_not_receive(:partitions)

        partitions = subject.incremental_partitions(build)
        partitions.should be_empty
      end
    end
  end

  describe "#depends_on_map" do
    it "should convert a dependency map to a depends on map" do
      subject.stub(:module_dependency_map).and_return({
          "module-one" => ["a", "b", "c"].to_set,
          "module-two" => ["b", "c", "module-one"].to_set,
          "module-three" => Set.new
      })

      depends_on_map = subject.depends_on_map

      depends_on_map["module-one"].should == ["module-one", "module-two"].to_set
      depends_on_map["module-two"].should == ["module-two"].to_set
      depends_on_map["module-three"].should == ["module-three"].to_set
      depends_on_map["a"].should == ["a", "module-one"].to_set
      depends_on_map["b"].should == ["b", "module-one", "module-two"].to_set
      depends_on_map["c"].should == ["c", "module-one", "module-two"].to_set
    end
  end

  describe "#module_dependency_map" do
    let(:top_level_pom) { <<-POM
<project>
  <modules>
    <module>module-one</module>
    <module>module-two</module>
    <module>module-three</module>
  </modules>
</project>
POM
    }

    let(:module_one_pom) { <<-POM
<project>
  <groupId>com.squareup</groupId>
  <artifactId>module-core</artifactId>

  <dependencies>
    <dependency>
      <groupId>com.squareup</groupId>
      <artifactId>module-extras</artifactId>
    </dependency>
    <dependency>
      <groupId>junit</groupId>
      <artifactId>junit</artifactId>
    </dependency>
  </dependencies>
</project>
POM
    }

    let(:module_two_pom) { <<-POM
<project>
  <groupId>com.squareup</groupId>
  <artifactId>module-extras</artifactId>

  <dependencies>
    <dependency>
      <groupId>com.squareup</groupId>
      <artifactId>module-three</artifactId>
    </dependency>
  </dependencies>
</project>
POM
    }

    let(:module_three_pom) { <<-POM
<project>
  <groupId>com.squareup</groupId>
  <artifactId>module-three</artifactId>

  <dependencies>
    <dependency>
      <groupId>junit</groupId>
      <artifactId>junit</artifactId>
    </dependency>
  </dependencies>
</project>
POM
    }

    it "it should get the transitive dependencies from a pom" do
      File.stub(:read).with(MavenPartitioner::POM_XML).and_return(top_level_pom)
      File.stub(:read).with("module-one/pom.xml").and_return(module_one_pom)
      File.stub(:read).with("module-two/pom.xml").and_return(module_two_pom)
      File.stub(:read).with("module-three/pom.xml").and_return(module_three_pom)

      dependency_map = subject.module_dependency_map

      dependency_map["module-one"].should == ["module-one", "module-two", "module-three"].to_set
      dependency_map["module-two"].should == ["module-two", "module-three"].to_set
      dependency_map["module-three"].should == ["module-three"].to_set
    end
  end

  describe "#transitive_dependencies" do
    it "should return the module in a set as a base case" do
      subject.transitive_dependencies("module-one", {"module-one" => Set.new}).should == ["module-one"].to_set
    end

    it "should work for the recursive case" do
      dependency_map = {
          "module-one" => ["a", "b", "c"].to_set,
          "a" => ["d"].to_set,
          "b" => ["d", "e"].to_set,
          "c" => Set.new,
          "d" => ["e"].to_set,
          "e" => Set.new,
          "f" => Set.new
      }

      transitive_map = subject.transitive_dependencies("module-one", dependency_map)
      transitive_map.should == ["module-one", "a", "b", "c", "d", "e"].to_set
    end
  end

  describe "#file_to_module" do
    before do
      File.stub(:exists?).and_return(false)
    end

    it "should return the module for a src main path" do
      File.stub(:exists?).with("beemo/pom.xml").and_return(true)
      subject.file_to_module("beemo/src/main/java/com/squareup/beemo/BeemoApp.java").should == "beemo"
    end

    it "should return the module in a subdirectory" do
      File.stub(:exists?).with("gateways/cafis/pom.xml").and_return(true)
      subject.file_to_module("gateways/cafis/src/main/java/com/squareup/gateways/cafis/data/DataField_9_6_1.java").should == "gateways/cafis"
    end

    it "should return the module for a src test path even if there is pom in the parent directory" do
      File.stub(:exists?).with("integration/hibernate/pom.xml").and_return(true)
      File.stub(:exists?).with("integration/hibernate/tests/pom.xml").and_return(true)
      subject.file_to_module("integration/hibernate/tests/src/test/java/com/squareup/integration/hibernate/ConfigurationExtTest.java").should == "integration/hibernate/tests"
    end

    it "should return a module for a pom change" do
      File.stub(:exists?).with("common/pom.xml").and_return(true)
      subject.file_to_module("common/pom.xml").should == "common"
    end

    it "should work for a toplevel change" do
      subject.file_to_module("pom.xml").should be_nil
      subject.file_to_module("Gemfile.lock").should be_nil
      subject.file_to_module("non_maven_dependencies/README").should be_nil
    end

    it "should return nil for changes in parents directory" do
      File.stub(:exists?).with("parents/base/pom.xml").and_return(true)
      subject.file_to_module("parents/base/pom.xml").should be_nil
    end
  end
end