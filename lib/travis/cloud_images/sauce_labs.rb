require 'travis-saucelabs-api'

module Travis
  module CloudImages
    class SauceLabs
      class VirtualMachine
        def initialize(provider, server)
          @provider = provider
          @server = server
        end

        def hostname
          if @server['extra_info'] && @server['extra_info']['hostname']
            @server['extra_info']['hostname']
          else
            @server['FQDN']
          end
        end

        def ip_address
          @server['public_ip']
        end

        def state
          @server['State']
        end

        def destroy
          @provider.destroy_server(self)
        end

        def instance_id
          @server['instance_id']
        end
      end

      attr_reader :account

      def initialize(account)
        @account = account
      end

      # create a connection
      def connection
        @connection ||= Travis::SaucelabsAPI.new(config.api_endpoint)
      end

      def servers
        connection.list_instances['instances'].map { |instance_id| VirtualMachine.new(self, connection.instance_info(instance_id)) }
      end

      def create_server(opts = {})
        startup_info = {}
        startup_info[:hostname] = opts[:hostname] if opts[:hostname]
        startup_info[:password] = opts[:password] if opts[:password]
        instance_id = connection.start_instance(startup_info, opts[:image_name] || 'ichef-osx8-10.8-working')['instance_id']
        connection.allow_outgoing(instance_id)
        VirtualMachine.new(self, connection.instance_info(instance_id))
      end

      def destroy_server(server)
        connection.kill_instance(server.instance_id)
      end

      def save_template(server, desc)
        timestamp = Time.now.utc.strftime('%Y-%m-%d-%H-%M')
        full_desc = "travis-#{desc}-#{timestamp}"

        connection.save_image(server.instance_id, full_desc)
      end

      def latest_template(type)
        { 'id' => 'ichef-osx8-10.8-working' }
      end

      def templates
        [{ 'id' => 'ichef-osx8-10.8-working' }]
      end

      def config
        @config ||= Config.new.sauce_labs[account.to_s]
      end
    end
  end
end