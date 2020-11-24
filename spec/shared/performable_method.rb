# frozen_string_literal: true

shared_examples_for 'Delayed::PerformableMethod' do

  it "should not ignore ActiveRecord::RecordNotFound errors because they are not always permanent" do
    story = Story.create :text => 'Once upon...'
    p = Delayed::PerformableMethod.new(story, :tell)
    story.destroy
    lambda { YAML.load(p.to_yaml) }.should raise_error(Delayed::Backend::RecordNotFound)
  end

  it "should store the object using native YAML even if its an active record" do
    story = Story.create :text => 'Once upon...'
    p = Delayed::PerformableMethod.new(story, :tell)
    p.class.should   == Delayed::PerformableMethod
    p.object.should  == story
    p.method.should  == :tell
    p.args.should    == []
    p.perform.should == 'Once upon...'
  end

  it "should allow class methods to be called on ActiveRecord models" do
    Story.create!(:text => 'Once upon a...')
    p = Delayed::PerformableMethod.new(Story, :count)
    lambda { expect(p.send(:perform)).to eql 1 }.should_not raise_error
  end

  it "should allow class methods to be called" do
    p = Delayed::PerformableMethod.new(StoryReader, :reverse, args: ["ohai"])
    lambda { p.send(:perform).should == "iaho" }.should_not raise_error
  end

  it "should allow module methods to be called" do
    p = Delayed::PerformableMethod.new(MyReverser, :reverse, args: ["ohai"])
    lambda { p.send(:perform).should == "iaho" }.should_not raise_error
  end

  it "should store arguments as native YAML if they are active record objects" do
    story = Story.create :text => 'Once upon...'
    reader = StoryReader.new
    p = Delayed::PerformableMethod.new(reader, :read, args: [story])
    p.class.should   == Delayed::PerformableMethod
    p.method.should  == :read
    p.args.should    == [story]
    p.perform.should == 'Epilog: Once upon...'
  end

  it "should deeply de-AR-ize arguments in full name" do
    story = Story.create :text => 'Once upon...'
    reader = StoryReader.new
    p = Delayed::PerformableMethod.new(reader, :read, args: [['arg1', story, { [:key, 1] => story }]])
    p.full_name.should == "StoryReader#read([\"arg1\", Story.find(#{story.id}), {[:key, 1] => Story.find(#{story.id})}])"
  end

  it "should call the on_failure callback" do
    story = Story.create :text => 'wat'
    p = Delayed::PerformableMethod.new(story, :tell, on_failure: :text=)
    p.send(:on_failure, 'fail')
    story.text.should == 'fail'
  end

  it "should call the on_permanent_failure callback" do
    story = Story.create :text => 'wat'
    p = Delayed::PerformableMethod.new(story, :tell, on_permanent_failure: :text=)
    p.send(:on_permanent_failure, 'fail_frd')
    story.text.should == 'fail_frd'
  end

  it "can still generate a name with no kwargs" do
    story = Story.create :text => 'wat'
    p = Delayed::PerformableMethod.new(story, :tell, kwargs: nil)
    expect(p.full_name).to eq("Story.find(#{story.id}).tell()")
  end
end
