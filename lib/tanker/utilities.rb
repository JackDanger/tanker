module Tanker
  module Utilities
    class << self
      def get_model_classes
        Tanker.included_in ? Tanker.included_in : []
      end

      def get_available_indexes
        get_model_classes.map{|model| model.tanker_config.index_name}.uniq.compact
      end

      def delete_index(index_name)
        index = Tanker.api.get_index(index_name)

        if index.exists?
          puts "Deleting #{index_name} index"
          index.delete_index
        end
      rescue => e
        puts "There was an error clearing the #{index_name} index: #{e.to_s}"
      end

      def build_index(index_name)
        index = Tanker.api.get_index(index_name)
        return if index.exists?

        puts "Creating #{index_name} index"
        index.create_index
        puts "Waiting for the index to be ready"
        while not index.running?
          sleep 0.5
        end
      rescue => e
        puts "There was an error creating the #{index_name} index: #{e.to_s}"
      end

      def clear_all_indexes
        get_available_indexes.each do |index_name|
          delete_index index_name
          build_index  index_name
        end
      end

      def reindex_all_models
        get_model_classes.each do |klass|
          klass.tanker_reindex
        end
      rescue => error
        puts error.to_s
      end

      def instantiate_results(index_result)
        results = index_result['results']
        return [] if results.empty?

        id_map = results.inject({}) do |acc, result|
          model, id = result["docid"].split(" ", 2)
          acc[model] ||= []
          acc[model] << id.to_i
          acc
        end

        if 1 == id_map.size # check for simple case, just one model involved
          klass = constantize(id_map.keys.first)
          # eager-load and return just this model's records
          ensure_order klass.find(id_map.values.first), id_map.values.first
        else # complex case, multiple models involved
          id_map.each do |klass, ids|
            # replace the id list with an eager-loaded list of records for this model
            id_map[klass] = ensure_order constantize(klass).find(ids), ids
          end
          results.map do |result|
            model, id = result["docid"].split(" ", 2)
            id_map[model].detect {|record| id.to_i == record.id }
          end
        end
      end

      def constantize(klass_name)
        Object.const_defined?(klass_name) ?
                  Object.const_get(klass_name) :
                  Object.const_missing(klass_name)
      end

      protected

        def ensure_order(records, ids)
          ordered_records = []
          ids.each do |id|
            ordered_records << records.detect {|r| r.id == id }
          end
          ordered_records
        end
    end
  end
end
