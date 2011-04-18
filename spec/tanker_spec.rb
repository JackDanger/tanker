require File.expand_path(File.join(File.dirname(__FILE__), 'spec_helper'))

describe Tanker do

  describe "configuration" do

    it 'sets configuration' do
      conf =  {:url => 'http://api.indextank.com'}
      Tanker.configuration = conf

      Tanker.configuration.should == conf
    end

    it 'checks for configuration when the module is included' do
      Tanker.configuration = nil

      lambda {
        Class.new.send(:include, Tanker)
      }.should raise_error(Tanker::NotConfigured)
    end

    it 'should not add model to .included_in if not configured' do
      Tanker.configuration = nil
      begin
        dummy_class = Class.new
        dummy_class.send(:include, Tanker)
      rescue Tanker::NotConfigured => e
        Tanker.included_in.should_not include dummy_class
      end
    end

  end

  describe ".tankit" do

    before :each do
      Tanker.configuration = {:url => 'http://api.indextank.com'}
      @dummy_class = Class.new do
        include Tanker
      end
    end

    after :each do
      Tanker.instance_variable_set(:@included_in, Tanker.included_in - [@dummy_class])
    end

    it 'should require a block when setting up tanker model' do
      lambda {
        @dummy_class.send(:tankit, 'dummy index')
      }.should raise_error(Tanker::NoBlockGiven)
    end

    it 'should set indexable fields' do
      @dummy_class.send(:tankit, 'dummy index') do
        indexes :field
      end

      dummy_instance = @dummy_class.new
      dummy_instance.tanker_config.indexes.any? {|field, block| field == :field }.should == true
    end

    it 'should allow blocks for indexable field data' do
      @dummy_class.send(:tankit, 'dummy index') do
        indexes :class_name do
          self.class.name
        end
      end

      dummy_instance = @dummy_class.new
      dummy_instance.tanker_config.indexes.any? {|field, block| field == :class_name }.should == true
    end

    it 'should set categories' do
      @dummy_class.send(:tankit, 'dummy index') do
        categories do
          { 'foo' => foo }
        end
      end

      dummy_instance = @dummy_class.new
      dummy_instance.stub!(:foo => "bar")
      dummy_instance.tanker_index_options[:categories] == { 'foo' => 'bar' }
    end

    it 'should overwrite the previous index name if provided' do
      @dummy_class.send(:tankit, 'first index') do
      end
      @dummy_class.send(:tankit, 'second index') do
      end

      dummy_instance = @dummy_class.new
      dummy_instance.tanker_config.index_name.should == 'second index'
    end

    it 'should keep the previous index name if not provided' do
      @dummy_class.send(:tankit, 'dummy index') do
      end
      @dummy_class.send(:tankit) do
      end

      dummy_instance = @dummy_class.new
      dummy_instance.tanker_config.index_name.should == 'dummy index'
    end

    it 'should keep previously indexed fields' do
      @dummy_class.send(:tankit, 'dummy index') do
        indexes :something
      end
      @dummy_class.send(:tankit, 'dummy index') do
        indexes :something_else
      end

      dummy_instance = @dummy_class.new
      Hash[*dummy_instance.tanker_config.indexes.flatten].keys.should == [:something, :something_else]
    end

    it 'should overwrite previously indexed fields if re-indexed' do
      @dummy_class.send(:tankit, 'dummy index') do
        indexes :something do
          "first"
        end
      end
      @dummy_class.send(:tankit, 'dummy index') do
        indexes :something do
          "second"
        end
      end

      dummy_instance = @dummy_class.new
      dummy_instance.stub!(:id => 1)
      dummy_instance.tanker_index_data[:something].should == "second"
    end

    it 'should merge with previously defined variables' do
      @dummy_class.send(:tankit, 'dummy index') do
        variables do
          {
            0 => 3.1415927,
            1 => 2.7182818
          }
        end
      end
      @dummy_class.send(:tankit, 'dummy index') do
        variables do
          {
            0 => 1.618034
          }
        end
      end

      dummy_instance = @dummy_class.new
      dummy_instance.tanker_index_options[:variables].should == { 0 => 1.618034, 1 => 2.7182818 }
    end

    it 'should merge with previously defined categories' do
      @dummy_class.send(:tankit, 'dummy index') do
        categories do
          {
            "undies" => "boxers",
            "cheese" => "cheddar"
          }
        end
      end
      @dummy_class.send(:tankit, 'dummy index') do
        categories do
          {
            "undies" => "briefs",
            "drives" => "prius"
          }
        end
      end

      dummy_instance = @dummy_class.new
      dummy_instance.tanker_index_options[:categories].should == { "undies" => "briefs", "cheese" => "cheddar", "drives" => "prius" }
    end

    it "can be initially defined in one module and extended in the including class" do
      dummy_module = Module.new do
        def self.included(base)
          base.send :include, Tanker

          base.tankit 'dummy index' do
            indexes :name
          end
        end
      end

      dummy_class = Class.new do
        include dummy_module

        tankit 'another index' do
          indexes :email
        end
      end

      dummy_instance = dummy_class.new
      dummy_instance.tanker_config.index_name.should == 'another index'
      Hash[*dummy_instance.tanker_config.indexes.flatten].keys.should == [:name, :email]

      Tanker.instance_variable_set(:@included_in, Tanker.included_in - [dummy_class])
    end
  end

  describe 'tanker instance' do
    it 'should create an api instance' do
      Tanker.api.class.should == IndexTank::ApiClient
    end

    it 'should create a connexion to index tank' do
      Person.tanker_index.class.should == IndexTank::IndexClient
    end

    it 'should be able to perform a seach query directly on the model' do
      Person.tanker_index.should_receive(:search).and_return(
        {
          "matches" => 1,
          "results" => [{
            "docid"  => Person.new.it_doc_id,
            "name"   => 'pedro',
            "__type" => 'Person',
            "__id"   => '1'
          }],
          "search_time" => 1
        }
      )

      Person.should_receive(:find).and_return(
      [Person.new]
      )

      collection = Person.search_tank('hey!')
      collection.class.should == WillPaginate::Collection
      collection.total_entries.should == 1
      collection.total_pages.should == 1
      collection.per_page.should == 10
      collection.current_page.should == 1
    end

    it 'should be able to use multi-value query phrases' do
      Person.tanker_index.should_receive(:search).with(
        "__any:(hey! location_id:(1) location_id:(2)) __type:(Person)",
        {:start => 0, :len => 10, :fetch => "__type,__id"}
      ).and_return({'results' => [], 'matches' => 0})

      collection = Person.search_tank('hey!', :conditions => {:location_id => [1,2]})
    end

    it 'should be able to use filter_functions' do
      Person.tanker_index.should_receive(:search).with(
        "__any:(hey!) __type:(Person)",
        { :start => 0,
          :len => 10,
          :filter_function2 => "0:10,20:40",
          :fetch => "__type,__id"
        }
      ).and_return({'results' => [], 'matches' => 0})

      collection = Person.search_tank('hey!',
                                      :filter_functions => {
                                        2 => [[0,10], [20,40]]
                                      })
    end
    it 'should be able to use filter_docvars' do
      Person.tanker_index.should_receive(:search).with(
        "__any:(hey!) __type:(Person)",
        { :start => 0,
          :len => 10,
          :filter_docvar3 => "*:7,80:100",
          :fetch => "__type,__id"
        }
      ).and_return({'results' => [], 'matches' => 0})

      collection = Person.search_tank('hey!',
                                      :filter_docvars => {
                                        3 => [['*',7], [80,100]]
                                      })
    end

    it 'should be able to perform a seach query over several models' do
      index = Tanker.api.get_index('animals')
      Dog.should_receive(:tanker_index).and_return(index)
      index.should_receive(:search).and_return(
        {
          "matches" => 2,
          "results" => [{
            "docid"  => 'Dog 7',
            "name"   => 'fido',
            "__type" => 'Dog',
            "__id"   => '7'
          },
          {
            "docid"  => 'Cat 9',
            "name"   => 'fluffy',
            "__type" => 'Cat',
            "__id"   => '9'
          }],
          "search_time" => 1
        }
      )

      Dog.should_receive(:find).and_return(
        [Dog.new(:name => 'fido', :id => 7)]
      )
      Cat.should_receive(:find).and_return(
        [Cat.new(:name => 'fluffy', :id => 9)]
      )

      collection = Tanker.search([Dog, Cat], 'hey!')
      collection.class.should == WillPaginate::Collection
      collection.total_entries.should == 2
      collection.total_pages.should == 1
      collection.per_page.should == 10
      collection.current_page.should == 1
    end

    it 'should be able to update the index' do
      person = Person.new(:name => 'Name', :last_name => 'Last Name')

      Person.tanker_index.should_receive(:add_document).with(
        Person.new.it_doc_id,
        {
          :__any     => "#{$frozen_moment.to_i} . Last Name . Name",
          :__type    => 'Person',
          :__id      => 1,
          :name      => 'Name',
          :last_name => 'Last Name',
          :timestamp => $frozen_moment.to_i
        },
        {
          :variables => {
            0 => 1.0,
            1 => 20.0,
            2 => 300.0
          }
        }
      )

      person.update_tank_indexes
    end

    it 'should be able to batch update the index' do
      person = Person.new(:name => 'Name', :last_name => 'Last Name')

      Person.tanker_index.should_receive(:add_documents).with(
        [ {
            :docid => Person.new.it_doc_id,
            :fields => {
              :__any     => "#{$frozen_moment.to_i} . Last Name . Name",
              :__type    => 'Person',
              :__id      => 1,
              :name      => 'Name',
              :last_name => 'Last Name',
              :timestamp => $frozen_moment.to_i
            },
            :variables => {
              0 => 1.0,
              1 => 20.0,
              2 => 300.0
            }
        } ]
      )

      Tanker.batch_update([person])
    end

    it 'should be able to delete the document from the index' do
      person = Person.new

      Person.tanker_index.should_receive(:delete_document)

      person.delete_tank_indexes
    end

    describe 'facets' do
      it 'search results object should respond to :facets' do
        Person.tanker_index.should_receive(:search).and_return({
          "matches" => 1,
          "results" => [
            {"docid" => "Person 1", "__type" => "Person", "__id" => "1"}
          ],
          "facets" => {
            "job" => {
              "tiny dancer" => 1
            }
          }
        })
        Person.should_receive(:find).and_return([Person.new])

        results = Person.search_tank('hey!')
        results.should respond_to :facets
      end

      it 'facets is a nested hash of category, values, and counts' do
        Person.tanker_index.should_receive(:search).and_return({
          "matches" => 1,
          "results" => [
            {"docid" => "Person 1", "__type" => "Person", "__id" => "1"}
          ],
          "facets" => {
            "job" => {
              "tiny dancer" => 1
            }
          }
        })
        Person.should_receive(:find).and_return([Person.new])

        results = Person.search_tank('hey!')
        results.facets.should == { 'job' => { 'tiny dancer' => 1 } }
      end

      it ':category_filters option gets passed to client as JSON' do
        Person.tanker_index.should_receive(:search)
          .with(anything, hash_including(:category_filters => '{"type":"Person"}'))
          .and_return(nil)
        Tanker.stub!(:instantiate_results => [Person.new])

        Person.search_tank('hey!', :category_filters => { 'type' => Person.name })
      end
    end

  end
end
