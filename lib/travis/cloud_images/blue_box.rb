require 'fog'
require 'shellwords'
require 'travis/cloud_images/cli/image_creation'

module Travis
  module CloudImages
    class BlueBox
      class VirtualMachine
        def initialize(server)
          @server = server
        end

        def vm_id
          @server.id
        end

        def hostname
          @server.hostname
        end

        def ip_address
          @server.ips.first['address']
        end

        def username
          'travis'
        end
        def state
          @server.state
        end

        def destroy
          @server.destroy
        end
      end

      attr_reader :account

      def initialize(account)
        @account = account
      end

      # create a connection
      def connection
        @connection ||= Fog::Compute.new(
          :provider            => 'Bluebox',
          :bluebox_customer_id => config.customer_id,
          :bluebox_api_key     => config.api_key
        )
      end

      def servers
        connection.servers.map { |server| VirtualMachine.new(server) }
      end

      def create_server(opts = {})
        defaults = {
          :username    => 'travis',
          :image_id    => config.image_id[(opts[:dist] || ::Travis::CloudImages::Cli::ImageCreation::DEFAULT_DIST).to_sym],
          :flavor_id   => config.flavor_id,
          :location_id => config.location_id
        }
        options = defaults.merge(opts)
        puts "options: #{options}"
        server = connection.servers.create(options)
        server.wait_for { ready? }
        VirtualMachine.new(server)
      end

      def save_template(server, desc)
        full_desc = "travis-#{desc}"

        connection.create_template(server.vm_id, :description => full_desc)

        while !find_template(full_desc)
          sleep(3)
        end
      end

      def latest_template_matching(regexp)
        travis_templates.
          sort_by { |t| t['created'] }.reverse.
          find { |t| t['description'] =~ Regexp.new(regexp) }
      end

      def latest_template(type)
        latest_template_matching(type)
      end

      def latest_released_template(type)
        latest_template_matching("^travis-#{Regexp.quote(type)}")
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
        @config ||= Config.new.blue_box[account.to_s]
      end
    end
  end
end