# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)

require 'minitest/autorun'
require 'minitest/hooks'
require 'minitest/pride'

require 'sequel'

DB = Sequel.connect("postgres:///sequel-search-path-test", search_path: 'public')

DB.extension :search_path

DB.freeze
