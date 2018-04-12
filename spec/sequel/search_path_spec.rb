# frozen_string_literal: true

require 'spec_helper'

class SearchPathSpec < Minitest::Spec
  include Minitest::Hooks

  def assert_schemas(*schemas)
    assert_equal schemas.first,      DB.active_schema
    assert_equal schemas,            DB.schemas
    assert_equal schemas.join(', '), DB.search_path
  end

  before do
    assert_schemas :public
  end

  after do
    assert_schemas :public
  end

  describe "when defaulting the schemas setting" do
    def assert_default(expected:, search_path:)
      DB.synchronize do |conn|
        conn.async_exec "SET search_path TO #{search_path}"

        key = DB.send(:schemas_key)
        Thread.current[key] = nil
        schemas = DB.schemas
        conn.async_exec "SET search_path TO public"
        Thread.current[key] = nil

        assert_equal expected, schemas
      end
    end

    it "should use whatever the search_path is" do
      assert_default expected: [:public], search_path: "public"
      assert_default expected: [:public, :schema1], search_path: "public, schema1"
      assert_default expected: [:schema2, :public, :schema1], search_path: "schema2,   public, schema1"
      assert_default expected: [:public], search_path: '"$user", public'
    end
  end

  it "should change the search_path inside the block" do
    DB.use_schema :schema1 do
      assert_schemas :schema1, :public
    end

    assert_schemas :public

    DB.override_schema :schema1 do
      assert_schemas :schema1
    end
  end

  it "should work with multiple schemas in a given order" do
    DB.use_schema :schema1, :schema2 do
      assert_schemas :schema1, :schema2, :public
    end

    assert_schemas :public

    DB.override_schema :schema1, :schema2 do
      assert_schemas :schema1, :schema2
    end
  end

  it "should stack schemas when called repeatedly" do
    DB.use_schema :schema1, :public do
      assert_schemas :schema1, :public

      DB.use_schema :schema2 do
        assert_schemas :schema2, :schema1, :public

        # There's no use case for passing nothing to use_schema, but if we
        # pass invoke it programmatically it may happen. Make sure that things
        # don't fail because of it.
        DB.use_schema do
          assert_schemas :schema2, :schema1, :public
        end

        assert_schemas :schema2, :schema1, :public
      end

      assert_schemas :schema1, :public
    end

    assert_schemas :public

    DB.override_schema :schema1, :public do
      assert_schemas :schema1, :public

      DB.use_schema :schema2 do
        assert_schemas :schema2, :schema1, :public
      end

      DB.override_schema :schema2 do
        assert_schemas :schema2

        DB.use_schema :schema3 do
          assert_schemas :schema3, :schema2

          # There's no use case for removing the search_path entirely, but if
          # we invoke override_schema programmatically it may happen. Make
          # sure that things don't fail because of it.
          DB.override_schema do
            assert_equal [],   DB.schemas
            assert_equal '""', DB.search_path

            DB.use_schema :schema4 do
              assert_schemas :schema4
            end

            assert_equal [],   DB.schemas
            assert_equal '""', DB.search_path
          end
        end

        assert_schemas :schema2
      end

      assert_schemas :schema1, :public
    end
  end

  it "should not duplicate schemas in the search_path" do
    DB.use_schema :schema1 do
      assert_schemas :schema1, :public

      DB.use_schema :schema2 do
        assert_schemas :schema2, :schema1, :public

        DB.use_schema :schema2 do
          assert_schemas :schema2, :schema1, :public

          DB.use_schema :schema1 do
            assert_schemas :schema1, :schema2, :public

            DB.use_schema :public do
              assert_schemas :public, :schema1, :schema2
            end

            assert_schemas :schema1, :schema2, :public
          end

          assert_schemas :schema2, :schema1, :public
        end

        assert_schemas :schema2, :schema1, :public
      end

      assert_schemas :schema1, :public
    end

    assert_schemas :public

    DB.override_schema :schema1 do
      assert_schemas :schema1

      DB.override_schema :schema1 do
        assert_schemas :schema1

        DB.override_schema :schema2, :schema1, :schema2, :public, :public do
          assert_schemas :schema2, :schema1, :public

          DB.override_schema :schema1, :public, :schema1, :schema2, :public do
            assert_schemas :schema1, :public, :schema2

            DB.use_schema :schema2 do
              assert_schemas :schema2, :schema1, :public
            end

            assert_schemas :schema1, :public, :schema2
          end

          assert_schemas :schema2, :schema1, :public
        end

        assert_schemas :schema1
      end

      assert_schemas :schema1
    end

    DB.override_schema :public, :schema1, 'public', 'schema1', :"public", :"schema1" do
      assert_schemas :public, :schema1
    end
  end

  it "should escape bad input" do
    DB.drop_table?(:blah)
    DB.create_table(:blah)

    DB.use_schema "schema1; DROP TABLE blah; --" do
      assert_equal [:"schema1; DROP TABLE blah; --", :public], DB.schemas
      assert_equal "\"schema1; DROP TABLE blah; --\", public", DB.show_search_path
    end

    DB.override_schema "schema1; DROP TABLE blah; --" do
      assert_equal [:"schema1; DROP TABLE blah; --"],  DB.schemas
      assert_equal "\"schema1; DROP TABLE blah; --\"", DB.show_search_path
    end

    assert DB.table_exists?(:blah)
    DB.drop_table(:blah)
  end

  it "should quote identifiers" do
    DB.use_schema "-schema_name", 'public' do
      assert_equal [:"-schema_name", :public], DB.schemas
      assert_equal "\"-schema_name\", public", DB.show_search_path
    end

    DB.use_schema "--schema_name", 'public' do
      assert_equal [:"--schema_name", :public], DB.schemas
      assert_equal "\"--schema_name\", public", DB.show_search_path
    end

    DB.use_schema :'-schema_name', :public do
      assert_equal [:'-schema_name', :public], DB.schemas
      assert_equal "\"-schema_name\", public", DB.show_search_path
    end

    DB.use_schema :'--schema_name', :public do
      assert_equal [:'--schema_name', :public], DB.schemas
      assert_equal "\"--schema_name\", public", DB.show_search_path
    end
  end

  it "should change the search_path inside the block, even when containing a transaction" do
    DB.use_schema :schema1, :schema2 do
      assert_schemas :schema1, :schema2, :public

      DB.transaction do
        assert_schemas :schema1, :schema2, :public

        DB.tables

        assert_schemas :schema1, :schema2, :public
      end

      assert_schemas :schema1, :schema2, :public
    end
  end

  it "should change the search_path inside the block, even when contained by a transaction" do
    DB.transaction do
      assert_schemas :public

      DB.use_schema :schema1, :schema2 do
        assert_schemas :schema1, :schema2, :public

        DB.tables

        assert_schemas :schema1, :schema2, :public
      end

      assert_schemas :public
    end
  end

  it "when containing a transaction should reraise errors and reset the schema properly" do
    error = assert_raises Sequel::DatabaseError do
      DB.use_schema :schema1, :schema2 do
        assert_schemas :schema1, :schema2, :public

        begin
          DB.transaction do
            assert_schemas :schema1, :schema2, :public

            begin
              DB[:nonexistent_table].all
            rescue
              assert_equal [:schema1, :schema2, :public], DB.schemas
              raise
            end
          end
        rescue
          assert_schemas :schema1, :schema2, :public
          raise
        end
      end
    end
    assert_match /relation "nonexistent_table" does not exist/, error.message
  end

  it "when containing a transaction should reraise errors and reset the schema properly when stacked" do
    error = assert_raises Sequel::DatabaseError do
      DB.use_schema :schema1 do
        assert_schemas :schema1, :public

        begin
          DB.transaction do
            assert_schemas :schema1, :public

            begin
              DB.use_schema :schema2 do
                assert_schemas :schema2, :schema1, :public

                begin
                  DB[:nonexistent_table].all
                rescue
                  assert_equal [:schema2, :schema1, :public], DB.schemas
                  raise
                end
              end
            rescue
              assert_equal [:schema1, :public], DB.schemas
              raise
            end
          end
        rescue
          assert_schemas :schema1, :public
          raise
        end
      end
    end

    assert_match /relation "nonexistent_table" does not exist/, error.message
  end

  it "when contained by a transaction should reraise errors and reset the schema properly" do
    error = assert_raises Sequel::DatabaseError do
      DB.transaction do
        assert_schemas :public

        DB.use_schema :schema1, :schema2 do
          assert_schemas :schema1, :schema2, :public

          begin
            DB[:nonexistent_table].all
          rescue
            assert_equal [:schema1, :schema2, :public], DB.schemas
            raise
          end
        end

        assert_equal [:public], DB.schemas
      end
    end

    assert_match /relation "nonexistent_table" does not exist/, error.message
  end

  it "when contained by a transaction should reraise errors and reset the schema properly when stacked" do
    error = assert_raises Sequel::DatabaseError do
      DB.transaction do
        assert_schemas :public

        begin
          DB.use_schema :schema1 do
            assert_schemas :schema1, :public

            begin
              DB.use_schema :schema2 do
                assert_schemas :schema2, :schema1, :public

                begin
                  DB[:nonexistent_table].all
                rescue
                  assert_equal [:schema2, :schema1, :public], DB.schemas
                  raise
                end
              end
            rescue
              assert_equal [:schema1, :public], DB.schemas
              raise
            end
          end
        rescue
          assert_equal [:public], DB.schemas
          raise
        end
      end
    end

    assert_match /relation "nonexistent_table" does not exist/, error.message
  end

  it "when contained by a transaction should reset the schema properly in the event of a rollback" do
    DB.transaction do
      assert_schemas :public

      begin
        DB.use_schema :schema1, :schema2 do
          assert_schemas :schema1, :schema2, :public

          begin
            raise Sequel::Rollback
          rescue
            assert_equal [:schema1, :schema2, :public], DB.schemas
            raise
          end
        end
      rescue
        assert_equal [:public], DB.schemas
        raise
      end
    end
  end

  it "when contained by a savepoint should reset the schema properly in the event of an error" do
    DB.transaction do
      assert_schemas :public

      DB.use_schema :schema1 do
        assert_schemas :schema1, :public

        begin
          DB.transaction savepoint: true do
            begin
              DB.use_schema :schema2 do
                assert_schemas :schema2, :schema1, :public

                begin
                  DB[:nonexistent_table].all
                rescue
                  assert_equal [:schema2, :schema1, :public], DB.schemas
                  raise
                end
              end
            rescue
              assert_equal [:schema1, :public], DB.schemas
              raise
            end
          end
        rescue Sequel::DatabaseError
        end

        assert_schemas :schema1, :public
      end

      assert_schemas :public
    end
  end

  it "when contained by a savepoint should reset the schema properly in the event of a rollback" do
    DB.transaction do
      assert_schemas :public

      DB.use_schema :schema1 do
        assert_schemas :schema1, :public

        DB.transaction savepoint: true do
          begin
            DB.use_schema :schema2 do
              assert_schemas :schema2, :schema1, :public

              begin
                raise Sequel::Rollback
              rescue
                assert_equal [:schema2, :schema1, :public], DB.schemas
                raise
              end
            end
          rescue
            assert_equal [:schema1, :public], DB.schemas
            raise
          end
        end

        assert_schemas :schema1, :public
      end

      assert_schemas :public
    end
  end

  it "should ignore failed transaction errors when setting schemas directly" do
    error = assert_raises Sequel::DatabaseError do
      assert_schemas :public
      DB.transaction do
        begin
          DB.schemas = [:schema1]
          assert_schemas :schema1
          DB[:nonexistent_table].all
        ensure
          DB.schemas = [:public]
        end
      end
      assert_schemas :public
    end

    assert_match /relation "nonexistent_table" does not exist/, error.message
  end
end
