require 'hashr'
require 'yaml'
require 'active_support/core_ext/object/blank'

# Encapsulates the configuration necessary for travis-core.
#
# Configuration values will be read from a local file config/travis.yml.
#
module Travis
  module CloudImages
    class Config < Hashr
      class << self
        def load_file
          @load_file ||= YAML.load_file(filename) if File.exists?(filename) rescue {}
        end

        def filename
          @filename ||= File.expand_path('config/travis.yml')
        end
      end

      define  :blue_box => {}, :sauce_labs => {}, :open_stack => {}

      default :_access => [:key]

      def initialize(data = nil, *args)
        data ||= self.class.load_file
        super
      end
    end
  end
end