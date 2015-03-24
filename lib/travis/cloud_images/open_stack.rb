require 'fog'
require 'shellwords'
require 'timeout'
require 'pry'

module Travis
  module CloudImages
    class OpenStack
      class VirtualMachine
        attr_reader :server, :connection

        def initialize(server, connection)
          @server = server
          @connection = connection
        end

        def vm_id
          server.id
        end

        def hostname
          server.name
        end

        def ip_address
          server.floating_ip_addresses.first
        end

        def username
          'ubuntu'
        end

        def state
          server.state
        end

        def destroy
          if ip_obj = connection.addresses.detect {|addr| addr.ip == server.floating_ip_address }
            connection.release_address(ip_obj.id)
          end

          server.destroy
        end

        def create_image(name)
          server.create_image(name)
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
        connection.servers.map { |server| VirtualMachine.new(server, connection) }
      end

      def create_server(opts = {})
        user_data  = %Q{#! /bin/bash\nsudo useradd travis -m -s /bin/bash || true\n}
        user_data += %Q{echo travis:#{opts[:password]} | sudo chpasswd\n} if opts[:password]
        user_data += %Q{sudo sed -i '/travis/d' /etc/sudoers\n}
        user_data += %Q{echo "travis ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers\n}
        user_data += %Q{sudo sed -i '/PasswordAuthentication/ d' /etc/ssh/sshd_config\n}
        user_data += %Q{echo 'PasswordAuthentication yes' | tee -a /etc/ssh/sshd_config\n}
        user_data += %Q{sudo service ssh restart}

        server = connection.servers.create(
          name: opts[:hostname],
          flavor_ref: config.flavor_id,
          image_ref: opts[:image_id] || config.image_id[(opts[:dist] || ::Travis::CloudImages::Cli::ImageCreation::DEFAULT_DIST).to_sym],
          key_name: config.key_name,
          nics: [{ net_id: config.internal_network_id }],
          user_data: user_data
        )

        server.wait_for { ready? }

        ip = connection.allocate_address(config.external_network_id)

        connection.associate_address(server.id, ip.body["floating_ip"]["ip"])

        vm = VirtualMachine.new(server.reload, connection)

        # VMs are marked as ACTIVE when turned on
        # but they make take awhile to become available via SSH
        retryable(tries: 15, sleep: 6) do
          ::Net::SSH.start(vm.ip_address, 'ubuntu',{ :password => opts[:password], :keys => config.key_file_name, :paranoid => false }).shell
        end

        vm
      rescue
        release_ip(server)
      end

      def save_template(server, desc)
        full_desc = "travis-#{desc}"

        response = server.create_image(full_desc)

        image_reponse = response.body['image']
        image = @connection.images.get(image_reponse['id'])

        sleep_sec = 5

        status = Timeout::timeout(1800) do
          while !image.ready? do
            image.reload
            case image.status
            when 'DELETED'
              raise "image #{image.id} has been unexpectedly deleted"
            when 'ACTIVE'
              puts "image #{image.id} has been successfully saved"
              break
            else
              sleep sleep_sec
            end
          end
        end
      rescue => e
        release_ip(server)
        raise e # re-raise
      end

      def latest_template_matching(regexp)
        travis_templates.
          sort_by { |t| t.created_at }.reverse.
          find { |t| t.name =~ Regexp.new(regexp) }
      end

      def latest_template(type)
        latest_template_matching(type)
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
        templates.find { |t| t.name == name && t.status == 'ACTIVE' }
      end

      def config
        @config ||= Config.new.open_stack[account.to_s]
      end

      def retryable(opts=nil)
        opts = { :tries => 1, :on => Exception }.merge(opts || {})

        begin
          return yield
        rescue *opts[:on]
          if (opts[:tries] -= 1) > 0
            sleep opts[:sleep].to_f if opts[:sleep]
            retry
          end
          raise
        end
      end

      def release_ip(server)
        ip_obj = connection.addresses.detect {|addr| addr.ip == server.server.floating_ip_address }
        connection.release_address ip_obj.id
      end
    end
  end
end