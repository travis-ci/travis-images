require 'travis/cloud_images/config'
require 'travis/cloud_images/blue_box'
require 'travis/cloud_images/sauce_labs'
require 'travis/cloud_images/vm_provisioner'
require 'thor'
require 'digest'
require 'digest/sha1'
require 'openssl'
require 'securerandom'

$stdout.sync = true

module Travis
  module CloudImages
    module Cli
      class ImageCreation < Thor
        namespace "travis:images"

        class_option :provider, :aliases => '-p', :default => 'blue_box', :desc => 'which Cloud VM provider to use'
        class_option :account,  :aliases => '-a', :default => 'org',      :desc => 'which Cloud VM account to use eg. org, pro'

        desc 'create [IMAGE_TYPE]', 'Create and provision a VM, then save the template. Defaults to the "standard" image'
        def create(image_type = "standard")
          puts "\nAbout to create and provision #{image_type} template\n\n"

          password = generate_password

          opts = { :hostname => "provisioning.#{image_type}" }

          unless standard_image?(image_type)
            opts[:image_id] = provider.latest_template('standard')['id']
          end

          puts "Creating a vm with the following options: #{opts.inspect}\n\n"

          opts[:password] = password

          server = provider.create_server(opts)

          puts "VM created : "
          puts "  #{server.inspect}\n\n"

          puts "About to provision the VM using the credential:"
          puts "  travis@#{server.ip_address} #{password}\n\n"

          provisioner = VmProvisoner.new(server.ip_address, 'travis', password, image_type)

          puts "---------------------- STARTING THE TEMPLATE PROVISIONING ----------------------"
          result = provisioner.full_run(!standard_image?(image_type))
          puts "---------------------- TEMPLATE PROVISIONING FINISHED ----------------------"

          if result
            provider.save_template(server, image_type)
            server.destroy
            puts "#{image_type} template created!\n\n"
          else
            puts "Could not create the #{image_type} template due to a provisioning error\n\n"
          end

          puts "#{server.hostname} VM destroyed"
        end


        desc 'boot [IMAGE_TYPE]', 'Boot a VM for testing, defaults to "ruby"'
        method_option :name, :aliases => '-n', :desc => 'additional naming option as to help idenify booted instances'
        method_option :ipv6, :default => false, :type => :boolean, :desc => 'boot an ipv6 only vm, only supported by bluebox right now'
        def boot(image_type = 'ruby')
          password = generate_password

          name_addition = [options[:name], image_type].join('-')

          hostname = "debug-#{name_addition}-#{Time.now.to_i}"

          opts = {
            :hostname => hostname,
            :image_id => provider.latest_template(image_type)['id']
          }

          opts[:ipv6_only] = true if options["ipv6"]

          puts "\nCreating a vm with the following options:"
          puts "  #{opts.inspect}\n\n"

          opts[:password] = password

          server = provider.create_server(opts)

          puts "VM created:"
          puts " #{server.inspect}\n\n"

          puts "Connection details are:"
          puts "  ssh travis@#{server.ip_address}"
          puts "  password: #{password}"
        end


        desc 'destroy [NAME]', 'Destroy the VM named [NAME] used for testing'
        def destroy(name)
          servers_with_name(name).each do |server|
            server.destroy
            puts "VM '#{server.hostname}' destroyed"
          end
        end


        desc 'clean_up', 'Destroy all left off VMs used for provisioning'
        def clean_up
          servers = servers_with_name("provisioning.")

          destroyed = servers.map do |s|
            s.destroy
            puts "VM '#{s.hostname}' destroyed"
            s
          end

          puts "\n #{destroyed.size} provisioning VMs destroyed\n\n"
        end


        desc 'list [TYPE]', "Lists all the currently active VM's running, default is 'all'"
        def list(type = 'all')
          servers = provider.servers

          servers.sort! { |a,b| a.hostname <=> b.hostname }

          printf("%-30s %s\n", "Hostname", "State")
          print("----------------------------------------\n")

          servers.each do |server|
            name = server.hostname.gsub(/\.\w+\.blueboxgrid\.com/, '')
            #puts server.inspect
            printf("%-30s %s\n", name, server.state)
          end
        end

        private

        def provider
          @provider ||= provider_class.new(options["account"])
        end

        def provider_class
          { 'blue_box' => BlueBox, 'sauce_labs' => SauceLabs }[options["provider"]]
        end

        def generate_password
          Digest::SHA1.base64digest(OpenSSL::Random.random_bytes(30)).gsub(/[\&\+\/\=\\]/, '')[0..19]
        end

        def standard_image?(image_type)
          image_type == 'standard'
        end

        def servers_with_name(name)
          provider.servers.find_all { |s| s.hostname =~ /^#{name}/ }
        end
      end
    end
  end
end
