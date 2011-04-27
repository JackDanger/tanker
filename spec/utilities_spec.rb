require File.expand_path(File.join(File.dirname(__FILE__), 'spec_helper'))

describe Tanker::Utilities do

  before :each do
    @dummy_class = Class.new do
      include Tanker
    end
  end

  after :each do
    Tanker.instance_variable_set(:@included_in, Tanker.included_in - [@dummy_class])
  end

  it "should get the models where Tanker module was included" do
    (Tanker::Utilities.get_model_classes - [@dummy_class, Person, Dog, Cat]).should == []
  end

  it "should get the available indexes" do
    @dummy_class.send(:tankit, 'dummy index') do
    end
    Tanker::Utilities.get_available_indexes.should == ["people", "animals", "another index", "dummy index"]
  end

end
