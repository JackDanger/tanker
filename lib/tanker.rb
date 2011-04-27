
begin
  require "rubygems"
  require "bundler"

  Bundler.setup :default
rescue => e
  puts "Tanker: #{e.message}"
end
require 'indextank_client'
require 'tanker/configuration'
require 'tanker/utilities'
require 'will_paginate/collection'


if defined? Rails
  begin
    require 'tanker/railtie'
  rescue LoadError
  end
end

module Tanker

  class NotConfigured < StandardError; end
  class NoBlockGiven < StandardError; end
  class NoIndexName < StandardError; end

  extend Tanker::Configuration

  class << self
    attr_reader :included_in

    def api
      @api ||= IndexTank::ApiClient.new(Tanker.configuration[:url])
    end

    def included(klass)
      configuration # raises error if not defined

      @included_in ||= []
      @included_in << klass
      @included_in.uniq!

      klass.send :include, InstanceMethods
      klass.extend ClassMethods

      class << klass
        define_method(:per_page) { 10 } unless respond_to?(:per_page)
      end
    end

    def guess_index_name
      if defined?(Rails)
        if Rails.respond_to?(:application)
          "#{Rails.application.class.name.split('::').first.downcase}_#{Rails.env}"
        else
          "#{File.dirname(Rails.root)}_#{Rails.env}"
        end
      end
    end

    def batch_update(records)
      return false if records.empty?
      data = records.map do |record|
        options = record.tanker_index_options
        options.merge!( :docid => record.it_doc_id, :fields => record.tanker_index_data )
        options
      end
      records.first.class.tanker_index.add_documents(data)
    end

    def search(models, query, options = {})
      ids      = []
      models   = [models].flatten.uniq
      page     = (options.delete(:page) || 1).to_i
      per_page = (options.delete(:per_page) || models.first.per_page).to_i
      index    = models.first.tanker_index
      query    = query.join(' ') if Array === query

      if (index_names = models.map(&:tanker_config).map(&:index_name).uniq).size > 1
        raise "You can't search across multiple indexes in one call (#{index_names.inspect})"
      end

      # move conditions into the query body
      if conditions = options.delete(:conditions)
        conditions.each do |field, value|
          value = [value].flatten.compact
          value.each do |item|
            query += " #{field}:(#{item})"
          end
        end
      end

      # rephrase filter_functions
      if filter_functions = options.delete(:filter_functions)
        filter_functions.each do |function_number, ranges|
          options[:"filter_function#{function_number}"] = ranges.map{|r|r.join(':')}.join(',')
        end
      end

      # rephrase filter_docvars
      if filter_docvars = options.delete(:filter_docvars)
        filter_docvars.each do |var_number, ranges|
          options[:"filter_docvar#{var_number}"] = ranges.map{|r|r.join(':')}.join(',')
        end
      end

      # IndexTank expects a JSON_formatted map in the GET query variable
      options[:category_filters] = options[:category_filters].to_json if options[:category_filters]

      options[:fetch] = "__type,__id"

      query = "__any:(#{query.to_s}) __type:(#{models.map(&:name).join(' OR ')})"
      options = { :start => per_page * (page - 1), :len => per_page }.merge(options)
      results = index.search(query, options)

      @entries = WillPaginate::Collection.create(page, per_page) do |pager|
        # inject the result array into the paginated collection:
        pager.replace Utilities.instantiate_results(results)

        unless pager.total_entries
          # the pager didn't manage to guess the total count, do it manually
          pager.total_entries = results["matches"]
        end
      end

      @entries.extend ResultsMethods
      @entries.results = results
      @entries
    end
  end

  # these are the class methods added when Tanker is included
  # They're kept to a minimum to prevent namespace pollution
  module ClassMethods

    attr_accessor :tanker_config

    def tankit(name = nil, &block)
      name ||= Tanker.guess_index_name

      raise NoBlockGiven, 'Please provide a block' unless block_given?
      raise NoIndexName, "Please provide a name for this index" unless name || tanker_config

      self.tanker_config ||= ModelConfig.new(name.to_s, block)

      name ||= self.tanker_config.index_name

      self.tanker_config.index_name = name

      config = ModelConfig.new(name, block)
      config.indexes.each do |key, value|
        self.tanker_config.indexes << [key, value]
      end

      %w[variables categories].each do |method|
        unless config.send(method).empty?
          self.tanker_config.send(method) do
            instance_exec &config.send(method).first
          end
        end
      end
    end

    def search_tank(query, options = {})
      Tanker.search([self], query, options)
    end

    def tanker_index
      tanker_config.index
    end

    def tanker_reindex(options = {})
      puts "Indexing #{self} model"

      unless tanker_config.index.exists?
        Tanker::Utilities.build_index(tanker_config.index_name)
      end


      batches = []
      options[:batch_size] ||= 200
      records = options[:scope] ? send(options[:scope]).all : all
      record_size = records.size

      records.each_with_index do |model_instance, idx|
        batch_num = idx / options[:batch_size]
        (batches[batch_num] ||= []) << model_instance
      end

      timer = Time.now
      batches.each_with_index do |batch, idx|
        Tanker.batch_update(batch)
        puts "Indexed #{batch.size} records   #{(idx * options[:batch_size]) + batch.size}/#{record_size}"
      end
      puts "Indexed #{record_size} #{self} records in #{Time.now - timer} seconds"
    end

    def tanker_parse_doc_id(result)
      result['docid'].split(' ').last
    end
  end

  class ModelConfig
    attr_accessor :index_name

    def initialize(index_name, block)
      @index_name = index_name
      @indexes    = []
      @variables  = []
      @functions  = {}
      @categories = []
      instance_exec &block
    end

    def indexes(field = nil, &block)
      @indexes << [field, block] if field
      @indexes
    end

    def variables(&block)
      @variables << block if block
      @variables
    end

    def functions(&block)
      @functions = block.call if block
      @functions
    end

    def categories(&block)
      @categories << block if block
      @categories
    end

    def index
      @index ||= Tanker.api.get_index(index_name)
    end

  end

  # these are the instance methods included
  module InstanceMethods

    def tanker_config
      self.class.tanker_config || raise(NotConfigured, "Please configure Tanker for #{self.class.inspect} with the 'tankit' block")
    end

    def tanker_indexes
      tanker_config.indexes
    end

    def tanker_variables
      tanker_config.variables
    end

    def tanker_categories
      tanker_config.categories
    end

    # update a create instance from index tank
    def update_tank_indexes
      tanker_config.index.add_document(
        it_doc_id, tanker_index_data, tanker_index_options
      )
    end

    # delete instance from index tank
    def delete_tank_indexes
      tanker_config.index.delete_document(it_doc_id)
    end

    def tanker_index_data
      data = {}

      # attempt to autodetect timestamp
      if respond_to?(:created_at)
        data[:timestamp] = created_at.to_i
      end

      tanker_indexes.each do |field, block|
        val = block ? instance_exec(&block) : send(field)
        val = val.join(' ') if Array === val
        data[field.to_sym] = val.to_s unless val.nil?
      end

      data[:__any] = data.values.sort_by{|v| v.to_s}.join " . "
      data[:__type] = self.class.name
      data[:__id] = self.id

      data
    end

    def tanker_index_options
      options = {}

      unless tanker_variables.empty?
        options[:variables] = tanker_variables.inject({}) do |hash, variables|
          hash.merge(instance_exec(&variables))
        end
      end

      unless tanker_categories.empty?
        options[:categories] = tanker_categories.inject({}) do |hash, categories|
          hash.merge(instance_exec(&categories))
        end
      end

      options
    end

    # create a unique index based on the model name and unique id
    def it_doc_id
      self.class.name + ' ' + self.id.to_s
    end
  end

  module ResultsMethods
    attr_accessor :results

    def facets
      @results['facets']
    end
  end
end
