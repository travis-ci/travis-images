require 'fog'
require 'shellwords'

module Travis
  module CloudImages
    class OpenStack
      class VirtualMachine
        def initialize(server)
          @server = server
        end

        def vm_id
          @server.id
        end

        def hostname
          @server.name
        end

        def ip_address
          @server.addresses.values.flatten.detect { |x| x['OS-EXT-IPS:type'] == 'floating' }['addr']
        end

        def username
          'ubuntu'
        end

        def state
          @server.state
        end

        def destroy
          @server.disassociate_address(ip_address)
          @server.destroy
        end

        def create_image(name)
          @server.create_image(name)
        end
      end

      attr_reader :account

      def initialize(account)
        @account = account
      end

      # create a connection
      def connection
        @connection ||= Fog::Compute.new(
          provider: :openstack,
          openstack_api_key: config.api_key,
          openstack_username: config.username,
          openstack_auth_url: config.auth_url,
          openstack_tenant: config.tenant
        )
      end

      def servers
        connection.servers.map { |server| VirtualMachine.new(server) }
      end

      def create_server(opts = {})
        user_data  = "#! /bin/bash\nsudo useradd travis -m -s /bin/bash || true\n"
        user_data += "echo travis:#{opts[:password]} | sudo chpasswd\n" if opts[:password]
        user_data += 'echo "travis ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers'

        server = connection.servers.create(
          name: opts[:hostname],
          flavor_ref: config.flavor_id,
          image_ref: opts[:image_id] || config.image_id,
          key_name: config.key_name,
          nics: [{ net_id: config.internal_network_id }],
          user_data: user_data #sudo cp -R /home/ubuntu/.ssh /home/travis/.ssh\nsudo chown -R travis:travis /home/travis/.ssh"
        )
        
        server.wait_for { ready? }

        ip = connection.allocate_address(config.external_network_id)

        connection.associate_address(server.id, ip.body["floating_ip"]["ip"])
        
        VirtualMachine.new(server.reload)
      end

      def save_template(server, desc)
        timestamp = Time.now.utc.strftime('%Y-%m-%d-%H-%M')
        full_desc = "travis-#{desc}-#{timestamp}"

        image = server.create_image(full_desc)

        while !find_active_template(full_desc)
          sleep(3)
        end
      end

      def latest_template(type)
        travis_templates.select { |t| t.name =~ /^travis-#{type}/ }.sort { |a, b| b.created_at <=> a.created_at }.first || {}
      end

      def latest_template_id(type)
        latest_template(type).id
      end

      def templates
        connection.images
      end

      def travis_templates
        templates.find_all { |t| t.name =~ /^travis-/ }
      end

      def find_active_template(name)
        templates.find { |t| t.name == name && t.state == 'ACTIVE' }
      end

      def clean_up
        connection.servers.each { |server| server.destroy if server.state == 'ACTIVE' }
      end

      def config
        @config ||= Config.new.open_stack[account.to_s]
      end
    end
  end
end