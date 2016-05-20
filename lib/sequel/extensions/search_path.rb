# frozen_string_literal: true

require 'sequel/extensions/search_path/version'

module Sequel
  module SearchPath
    def use_schema(*new_schemas, &block)
      synchronize { override_schema(*(new_schemas + schemas), &block) }
    end

    def override_schema(*new_schemas, &block)
      synchronize do
        previous_schemas = schemas

        begin
          self.schemas = new_schemas
          yield
        ensure
          self.schemas = previous_schemas
        end
      end
    end

    def schemas
      Thread.current[schemas_key] ||= [:public]
    end

    def schemas=(schemas)
      schemas = schemas.map(&:to_sym).uniq
      Thread.current[schemas_key] = schemas

      # Set the search_path in Postgres, unless it's in transaction rollback.
      # If it is, the search_path will be reset for us anyway, and the SQL
      # call will just raise another error.
      unless synchronize(&:transaction_status) == PG::PQTRANS_INERROR
        set_search_path(schemas)
      end
    end

    # The schema that new objects will be created in.
    def active_schema
      schemas.first
    end

    def search_path
      self["SHOW search_path"].get
    end
    alias :show_search_path :search_path

    private

    def set_search_path(schemas)
      placeholders = schemas.map{'?'}.join(', ')
      placeholders = "''" if placeholders.empty?
      self["SET search_path TO #{placeholders}", *schemas].get
    end

    def schemas_key
      @schemas_key ||= "sequel-search-path-#{object_id}".to_sym
    end
  end

  Database.register_extension(:search_path){|db| db.extend(Sequel::SearchPath)}
end
