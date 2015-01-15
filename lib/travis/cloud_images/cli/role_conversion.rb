require 'pp'

module Travis
  module CloudImages
    module Cli
      class RoleConversion < Thor
        include Thor::Actions
        namespace "travis:roles"

        desc "convert FILES", "converts legacy YAML role files to a Chef roles"
        method_option :format, desc: 'The target Chef Role format', enum: %w(ruby json), default: 'ruby'
        def convert(*files)
          target_files = []
          files.each do |file|
            data = YAML.load File.read(file)
            name = File.basename(file, File.extname(file)).tr('.','_').tr('-','') # worker.node-js.yml -> worker_nodejs
            target_file = "roles/#{@name}.rb"
            target_files << target_file
            send "convert_to_#{options[:format]}".to_sym, data, name
          end
          if options[:format] == 'ruby'
            say "Formatting #{target_files}"
            `bundle exec rubocop -a #{target_files.join ' '} 2>/dev/null` # Supress invalid Rubocop warnings
          end
        end

        protected

        def convert_to_ruby(data, name)
          file = "roles/#{name}.rb"
          attributes = (data['json'] || {}).to_hash
          run_list = data['recipes'].map do |recipe|
            "recipe[#{recipe}]".inspect
          end.join ",\n"
          create_file file do
            buffer = StringIO.new
            buffer.puts "name '#{name}'"
            buffer.puts "description 'Auto-generated role for #{name}'"
            unless attributes.empty?
              buffer.print "default_attributes("
              PP.pp attributes, buffer
              buffer.puts ")"
            end
            buffer.puts "run_list(#{run_list})"
            buffer.string
          end
        end

        def convert_to_json(data, name)
          file = "roles/#{name}.json"
          role_data = {}
          role_data['name'] = name
          role_data['description'] = "Auto-generated role for #{name}"
          role_data['chef_type'] = 'role'
          role_data['json_class'] = 'Chef::Role'
          role_data['default_attributes'] = data['json']
          role_data['run_list'] = data['recipes'].map do | recipe |
            "recipe[#{recipe}]"
          end
          create_file file do
            JSON.pretty_generate role_data
          end
        end

      end
    end
  end
end
