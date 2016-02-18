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
      set_search_path(schemas)
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
    rescue Sequel::DatabaseError => e
      if e.wrapped_exception.is_a?(PG::InFailedSqlTransaction)
        # This command will fail if we're in a transaction that the DB is
        # rolling back due to an error, but in that case, there's no need to run
        # it anyway (Postgres will reset the search_path for us). Since there's
        # no way to know whether it will fail until we try it, and there's
        # nothing to be done with the error it throws, just ignore it.
      else
        raise
      end
    end

    def schemas_key
      @schemas_key ||= "sequel-search-path-#{object_id}".to_sym
    end
  end

  Database.register_extension(:search_path){|db| db.extend(Sequel::SearchPath)}
end
