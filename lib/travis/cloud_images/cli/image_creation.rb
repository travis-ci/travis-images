require 'travis/cloud_images/config'
require 'travis/cloud_images/blue_box'
require 'travis/cloud_images/vm_provisioner'
require 'thor'
require 'digest/sha1'
require 'securerandom'

$stdout.sync = true

module Travis
  module CloudImages
    module Cli
      class ImageCreation < Thor
        namespace "travis:images"

        desc 'create [IMAGE_TYPE]', 'Create and provision a VM, then save the template. Defaults to the "standard" image'
        def create(image_type = "standard")
          puts "\nAbout to create and provision #{image_type} template\n\n"
          
          password = generate_password
          
          opts = { :hostname => "provisioning.#{image_type}" }
          
          unless standard_image?(image_type)
            opts[:image_id] = blue_box.latest_template('standard')['id']
          end
          
          puts "Creating a vm with the following options: #{opts.inspect}\n\n"
          
          server = blue_box.create_server(password, opts)
          
          puts "VM created : "
          puts "  #{server.inspect}\n\n"
          
          puts "About to provision the VM using the credential:"
          puts "  travis@#{server.ips.first['address']} #{password}\n\n"
          
          provisioner = VmProvisoner.new(server.ips.first['address'], 'travis', password, image_type)
          
          puts "---------------------- STARTING THE TEMPLATE PROVISIONING ----------------------"
          result = provisioner.full_run
          puts "---------------------- TEMPLATE PROVISIONING FINISHED ----------------------"
          
          if result
            blue_box.save_template(server, image_type)
            server.destroy
            puts "#{image_type} template created!\n\n"
          else
            puts "Could not create the #{image_type} template due to a provisioning error\n\n"
          end
          
          puts "#{server.hostname} VM destroyed"
        end

        desc 'boot [IMAGE_TYPE]', 'Boot a VM for testing, defaults to "ruby"'
        def boot(image_type = 'ruby')
          password = generate_password
          
          opts = { 
            :hostname => "testing.#{image_type}.#{Time.now.to_i}",
            :image_id => blue_box.latest_template(image_type)['id']
          }
          
          puts "\nCreating a vm with the following options:"
          puts "  #{opts.inspect}\n\n"
          
          server = blue_box.create_server(password, opts)
          
          puts "VM created:"
          puts " #{server.inspect}\n\n"
          
          puts "Connection details are:"
          puts "  travis@#{server.ips.first['address']}"
          puts "  password: #{password}\n\n"
        end
        
        desc 'destroy [NAME]', 'Destroy the VM named [NAME] used for testing'
        def destroy(name)
          server = blue_box.servers.detect { |s| s.hostname =~ /^#{name}/ }
          
          server.destroy
          
          puts "VM '#{name}' destroyed"
        end
        
        desc 'generate_password', 'Generates a mostly unique password'
        def generate_password
          SecureRandom.urlsafe_base64(40)
        end
        
        desc 'clean_up', 'Destroy all left off VMs used for provisioning'
        def clean_up
          servers = blue_box.servers.find_all { |s| s.hostname =~ /^provisioning./ }
          
          destroyed = servers.map do |s|
            s.destroy
            puts "VM '#{s.hostname}' destroyed"
            s
          end
          
          puts "\n #{destroyed.size} provisioning VMs destroyed\n\n"
        end
        
        private
        
        def blue_box
          @blue_box ||= BlueBox.new
        end
        
        def standard_image?(image_type)
          image_type == 'standard'
        end

      end
    end
  end
end
