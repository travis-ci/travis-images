require 'net/ssh/shell'
require 'shellwords'
require 'yaml'
require 'faraday'

module Travis
  module CloudImages
    class VmProvisoner
      module Assets
        SOLO_RB = <<-RUBY
root = File.expand_path(File.dirname(__FILE__))
file_cache_path File.join(root, "cache")
cookbook_path [ "/tmp/vm-provisioning/travis-cookbooks/ci_environment" ]
log_level :debug
log_location STDOUT
verbose_logging false
RUBY
      end

      module Commands
        SETUP_ENV = [
          'sudo usermod -s /bin/bash travis',
          'sudo apt-get -y update',
          'sudo apt-get -y upgrade',
          'sudo apt-get -y install git-core curl build-essential bison openssl libreadline6 libreadline6-dev zlib1g zlib1g-dev libssl-dev libyaml-dev libxml2-dev libxslt1-dev autoconf libc6-dev libncurses5-dev vim wget',
          'sudo rm /dev/null',
          'sudo mknod -m 0666 /dev/null c 1 3',
          'sudo apt-get -y install --reinstall language-pack-en',
          'export LANG="en_US.UTF-8"'
        ]

        INSTALL_CHEF = [
          'mkdir -p /tmp/vm-provisioning',
          'cd /tmp/vm-provisioning',
          'sudo rm -rf ruby-build',
          'git clone -q git://github.com/sstephenson/ruby-build.git',
          'cd ruby-build',
          'sudo ./install.sh',
          'sudo ruby-build 1.9.3-p327 /usr/local',
          'sudo gem install chef --quiet --no-ri --no-rdoc',
          'sudo gem install ruby-shadow --quiet --no-ri --no-rdoc',
        ]

        PREP_CHEF = [
          'mkdir -p /tmp/vm-provisioning/assets/cache',
          "echo #{Shellwords.escape(Assets::SOLO_RB)} > /tmp/vm-provisioning/assets/solo.rb",
          'cd /tmp/vm-provisioning',
          'rm -rf travis-cookbooks',
          'git clone -b bluebox git://github.com/travis-ci/travis-cookbooks.git --depth 10',
        ]

        CLEAN_UP = [
          'rm -rf /tmp/vm-provisioning'
        ]
      end

      attr_reader :host
      attr_reader :log
      attr_reader :box_type

      def initialize(host, user, password, box_type = 'standard')
        @host = host
        @user = user
        @password = password
        @box_type = box_type
        @log  = ""
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
        shell.execute("echo #{Shellwords.escape("$ #{command}")}\n#{command}") do |process|
          process.on_output(&simple_output)
          process.on_error_output(&simple_output)
          process.on_finish { |p| status = p.exit_status }
        end
        shell.session.loop(1) { status.nil? }
        status
      end

      def run_commands(commands)
        commands.all? do |cmd|
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

      def prep_chef
        run_commands(Commands::PREP_CHEF)
      end

      def updated_run_list
        box_config = fetch_box_config

        build_env = {
          'travis_build_environment' => {
            'user' => 'travis',
            'group' => 'travis',
            'home' => "/home/travis"
          }
        }

        box_config['json'] ||= {}

        attributes = box_config['json'].merge(build_env)

        attributes.merge('run_list' => create_run_list(box_config))
      end

      def run_chef
        run_commands([
          "echo #{Shellwords.escape(MultiJson.encode(updated_run_list))} > /tmp/vm-provisioning/assets/solo.json",
          "sudo chef-solo -c /tmp/vm-provisioning/assets/solo.rb -j /tmp/vm-provisioning/assets/solo.json"
        ])
      end

      def clean_up
        run_commands(Commands::CLEAN_UP)
      end

      def full_run
        setup_env &&
        install_chef &&
        prep_chef &&
        run_chef &&
        clean_up
      end

      def fetch_box_config
        response = Faraday.get("https://raw.github.com/travis-ci/travis-boxes/more_separation/config/worker.#{box_type}.yml")
        YAML.load(response.body)
      end

      def create_run_list(box_config)
        box_config['recipes'].map { |r| "recipe[#{r}]" }
      end
    end
  end
end