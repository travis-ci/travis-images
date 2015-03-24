require 'net/ssh/shell'
require 'shellwords'
require 'yaml'
require 'faraday'

module Travis
  module CloudImages
    class VmProvisioner
      module Assets
        SOLO_RB = <<-RUBY
root = File.expand_path(File.dirname(__FILE__))
file_cache_path File.join(root, "cache")
cookbook_path [ "/tmp/vm-provisioning/travis-cookbooks/ci_environment" ]
log_location STDOUT
verbose_logging false
RUBY
      end

      module Commands
        SETUP_ENV = [
          'sudo usermod -s /bin/bash travis',
          'sudo apt-get -y update',
          'sudo apt-get -y -qq upgrade',
          'sudo apt-get -y -qq install bash curl build-essential bison openssl vim wget',
          'sudo rm /dev/null',
          'sudo mknod -m 0666 /dev/null c 1 3',
          'sudo apt-get -y install --reinstall language-pack-en',
          'export LANG="en_US.UTF-8"'
        ]

        INSTALL_CHEF = [
          'mkdir -p /tmp/vm-provisioning',
          'cd /tmp/vm-provisioning',
          'curl -L https://www.opscode.com/chef/install.sh | sudo bash -s -- -v 11.16.2-1'
        ]

        # It is important that there is exactly one
        PREP_CHEF = [
          'mkdir -p /tmp/vm-provisioning/assets/cache',
          "echo #{Shellwords.escape(Assets::SOLO_RB)} > /tmp/vm-provisioning/assets/solo.rb",
          'cd /tmp/vm-provisioning',
          'rm -rf travis-cookbooks',
          'curl -L https://api.github.com/repos/travis-ci/travis-cookbooks/tarball/%{branch} > travis-cookbooks.tar.gz',
          'tar xvf travis-cookbooks.tar.gz',
          'mv travis-ci-travis-cookbooks-* travis-cookbooks',
          'rm travis-cookbooks.tar.gz'
        ]

        CLEAN_UP = [
          'cd ~',
          'sudo rm -rf /tmp/vm-provisioning',
          'sudo rm -rf /opt/chef',
          'sudo apt-get clean'
        ]
      end

      attr_reader :host
      attr_reader :log
      attr_reader :box_type
      attr_reader :dist
      attr_reader :branch
      attr_reader :templates_path

      def initialize(host, user, password, box_type, dist, branch, templates_path)
        @host = host
        @user = user
        @password = password
        @box_type = box_type
        @dist = dist
        @log  = ""
        @branch = branch
        @templates_path = File.expand_path(templates_path)
      end

      def shell
        @shell ||= ::Net::SSH.start(host, @user, { :password => @password, :paranoid => false }).shell
      end

      def close_shell
        if @shell
          shell.close!
          @shell = nil
        end
      end

      def exec(command, &block)
        simple_output = block_given? ? block : lambda { |ch, data| log << data; print(data) }

        status = nil

        print("$ #{command}\n")

        shell.execute(command) do |process|
          process.on_output(&simple_output)
          process.on_error_output(&simple_output)
          process.on_finish { |p| status = p.exit_status }
        end
        shell.session.loop(1) { status.nil? }
        status
      end

      def run_commands(commands)
        Array(commands).all? do |cmd|
          status = exec(cmd)
          puts "'#{cmd}' failed :(" unless status == 0
          status == 0
        end
      end

      def setup_env
        run_commands(Commands::SETUP_ENV)
      end

      def install_chef
        run_commands(Commands::INSTALL_CHEF)
      end

      def prep_chef(cookbooks_branch = 'master')
        puts "Preparing Chef with branch: #{cookbooks_branch}"
        run_commands(Commands::PREP_CHEF.map{ |x| x % { branch: cookbooks_branch } })
      end

      def updated_run_list
        box_config['json'] ||= {}
        box_config['json'].merge!({'system_info' => {'cookbooks_sha' => sha_for_repo('travis-ci/travis-cookbooks')}})
        box_config['json'].merge('run_list' => create_run_list)
      end

      def run_chef
        run_commands([
          "sudo apt-get update -qq",
          "echo #{Shellwords.escape(MultiJson.encode(updated_run_list))} > /tmp/vm-provisioning/assets/solo.json",
          "sudo chef-solo -c /tmp/vm-provisioning/assets/solo.rb -j /tmp/vm-provisioning/assets/solo.json"
        ])
      end

      def clean_up
        run_commands(Commands::CLEAN_UP)
      end

      def full_run(opts)
        puts "Running #{__method__} with opts: #{opts}"
        (skip_setup?(opts) || setup_env) &&
        install_chef &&
        prep_chef(opts[:cookbooks_branch]) &&
        run_chef &&
        clean_up
      end

      def box_config
        @box_config ||= parse_template_configs
      end

      def parse_template_configs
        configs = [:common, :standard].map { |type| parse_template_config(type) }
        configs.inject({}) do |result, config|
          result['json'] = (result['json'] || {}).deep_merge(config['json'] || {})
          result['recipes'] = (result['recipes'] || []).concat(config['recipes'] || [])
          result
        end
      end

      def parse_template_config(type)
        path = File.expand_path("#{templates_path}/#{type}/#{box_type}.yml")
        File.exists?(path) ? YAML.load(File.read(path)) : {}
      end

      def create_run_list
        box_config['recipes'].map { |r| "recipe[#{r}]" }
      end

      def skip_setup?(opts)
        if opts[:custom_base_name] == false
          false
        else
          opts[:image_type] != 'standard'
        end
      end

      def sha_for_repo(slug, length = 7)
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
