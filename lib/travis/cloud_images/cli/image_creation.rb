require 'travis/cloud_images/config'
require 'travis/cloud_images/blue_box'
require 'travis/cloud_images/open_stack'
require 'travis/cloud_images/sauce_labs'
require 'travis/cloud_images/vm_provisioner'
require 'thor'
require 'digest'
require 'digest/sha1'
require 'openssl'
require 'securerandom'
require 'faraday'
require 'json'

$stdout.sync = true

module Travis
  module CloudImages
    module Cli
      class ImageCreation < Thor
        namespace "travis:images"

        DUP_MATCH_REGEX = /testing-worker-(\w+-\d+-\d+-\d+-\w+-\d+)-(\d+)/

        class_option :provider, :aliases => '-p', :default => 'blue_box', :desc => 'which Cloud VM provider to use'
        class_option :account,  :aliases => '-a', :default => 'org',      :desc => 'which Cloud VM account to use eg. org, pro'

        desc 'create [IMAGE_TYPE]', 'Create and provision a VM, then save the template. Defaults to the "standard" image'
        method_option :name, :aliases => '-n', :desc => 'optional VM naming prefix for the language. eg. travis-[prefix]-language-[date]'
        method_option :base, :aliases => '-b', :type => :boolean, :desc => 'override which base image to use'
        method_option :cookbooks_branch, :aliases => '-B', :default => 'master', :desc => 'travis-cookbooks branch name to use; defaults to "master"'
        method_option :keep, :aliases => '-k', :desc => 'In case of build failures, do keep provisioning VM for further inspection'
        def create(image_type = "standard")
          puts "#{DateTime.now}\nAbout to create and provision #{image_type} template\n\n"

          password = generate_password

          opts = { :hostname => "provisioning.#{image_type}" }

          if custom_base_image?(image_type, options[:base])
            opts[:image_id] = base_image(options[:base])
          end

          puts "Creating a vm with the following options: #{opts.inspect}\n\n"

          opts[:password] = password

          begin
            server = provider.create_server(opts)

            puts "VM created : "
            puts "  #{server.inspect}\n\n"

            puts "About to provision the VM using the credential:"
            puts "  travis@#{server.ip_address} #{password}\n\n"

            provisioner = VmProvisoner.new(server.ip_address, 'travis', password, image_type)

            puts "---------------------- STARTING THE TEMPLATE PROVISIONING ----------------------"
            result = provisioner.full_run(options.dup.merge(image_type: image_type))
            puts "---------------------- TEMPLATE PROVISIONING FINISHED ----------------------"
          rescue Exception => e
            puts "Error while creating image"
            puts e.message

            clean_up(server)
            return
          end

          if result
            desc = [options["name"], image_type, sha_for_repo('travis-ci/travis-cookbooks', options[:cookbooks_branch])].compact.join('-')
            provider.save_template(server, desc)
            clean_up(server)
            puts "#{image_type} template created!\n\n"
          else
            puts "Could not create the #{image_type} template due to a provisioning error\n\n"
            if options[:keep]
              puts "Preserving the provisioning VM\ntravis@#{server.ip_address} #{password}\n\n"
            else
              clean_up(server)
            end
          end

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
            :image_id => provider.latest_template_id(image_type)
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
          destroyed = false
          servers_with_name(name).each do |server|
            server.destroy
            puts "VM '#{server.hostname}' destroyed"
            destroyed = true
          end

          unless destroyed
            STDERR.puts "Could not find any VM matching /^#{name}/, did you mean one of these servers:"
            provider.servers.find_all { |s| p s.hostname if s.hostname =~ /#{Regexp.escape(name)}/ }
            exit 1
          end
        end


        desc 'clean_up', 'Destroy all left off VMs used for provisioning'
        def clean_up(servers = nil)
          servers ||= servers_with_name("provisioning.")

          destroyed = Array(servers).map do |s|
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
            printf("%-30s %s\n", name, server.state)
          end
        end

        desc 'duplicates', "Lists all possible duplicate VMs"
        method_option :destroy, :aliases => '-d', :desc => 'destroy duplicates'
        def duplicates
          servers = provider.servers

          grouped = servers.group_by do |s|
            match = DUP_MATCH_REGEX.match(s.hostname)
            match ? match[1] : nil
          end

          grouped.delete(nil)
          grouped.delete_if { |k,v| v.size < 2 }

          grouped.each do |k,v|
            v.sort! do |a,b|
              match1 = DUP_MATCH_REGEX.match(a.hostname)
              match2 = DUP_MATCH_REGEX.match(b.hostname)
              match1[2] <=> match2[2]
            end
            unless options[:destroy]
              printf("%-30s %s\n", "Hostname", "State")
              print("----------------------------------------\n")
            end
            v[0...-1].each do |server|
              if options[:destroy]
                server.destroy
                puts "VM '#{server.hostname}' destroyed"
              else
                name = server.hostname.gsub(/\.\w+\.blueboxgrid\.com/, '')
                printf("%-40s %s\n", name, server.state)
              end
            end
          end
        end

        private

        def provider
          @provider ||= provider_class.new(options["account"])
        end

        def provider_class
          { 'blue_box' => BlueBox, 'sauce_labs' => SauceLabs, 'open_stack' => OpenStack }[options["provider"]]
        end

        def generate_password
          Digest::SHA1.base64digest(OpenSSL::Random.random_bytes(30)).gsub(/[\&\+\/\=\\]/, '')[0..19]
        end

        def standard_image?(image_type)
          image_type == 'standard'
        end

        def custom_base_image?(image_type, custom_base_name)
          if custom_base_name
            true
          elsif custom_base_name == false
            false
          else
            image_type != 'standard'
          end
        end

        def base_image(custom_base_name = 'standard')
          provider.latest_template_id(custom_base_name)
        end

        def servers_with_name(name)
          provider.servers.find_all { |s| s.hostname =~ /^#{name}/ }
        end

        def sha_for_repo(slug, branch = 'master', length = 7)
          conn = Faraday.new(:url => "https://api.github.com") do |faraday|
            faraday.adapter Faraday.default_adapter
          end

          response = conn.get "/repos/#{slug}/git/refs/heads/#{branch}"
          data = JSON.parse(response.body)

          data["object"]["sha"][0,length]
        rescue
          'f' * length
        end
      end
    end
  end
end
