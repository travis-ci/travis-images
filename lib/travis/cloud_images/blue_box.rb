require 'fog'
require 'shellwords'

module Travis
  module CloudImages
    class BlueBox
      # create a connection
      def connection
        @connection ||= Fog::Compute.new(
          :provider            => 'Bluebox',
          :bluebox_customer_id => config.customer_id,
          :bluebox_api_key     => config.api_key
        )
      end

      def servers
        connection.servers
      end

      def create_server(password, opts = {})
        defaults = {
          :username  => 'travis',
          :password  => password,
          :image_id  => config.image_id,
          :flavor_id => config.flavor_id,
          :location_id => config.location_id
        }
        defaults.delete(:image_id) if opts[:template_id]
        server = connection.servers.create(defaults.merge(opts))
        server.wait_for { ready? }
        server
      end

      def save_template(server, desc)
        timestamp = Time.now.utc.strftime('%Y-%m-%d-%H-%M')
        full_desc = "travis-#{desc}-#{timestamp}"

        connection.create_template(server.id, :description => full_desc)

        while !find_template(full_desc)
          sleep(3)
        end
      end

      def latest_template(type)
        travis_templates.select { |t| t['description'] =~ /#{type}/ }.sort { |a, b| b['created'] <=> a['created'] }.first
      end

      def templates
        connection.get_templates.body
      end

      def private_templates
        templates.find_all { |t| t['public'] == false }
      end

      def travis_templates
        private_templates.find_all { |t| t['description'] =~ /^travis-/ }
      end

      def find_template(description)
        private_templates.find { |t| t['description'] == description }
      end

      def clean_up
        connection.servers.each { |server| server.destroy if ['running', 'error'].include?(server.state) }
      end

      def config
        @config ||= Config.new.blue_box
      end
    end
  end
end