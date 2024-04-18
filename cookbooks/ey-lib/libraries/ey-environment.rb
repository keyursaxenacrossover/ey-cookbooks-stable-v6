# AI-GEN START - chatgpt
###############################################################################
# ::Chef::EY::Environment
#
# Base Concepts:
# - There is no such thing as a language-defined environment. Instead, the
#   environment can support a single version of each potential language. Apps
#   will state what language they need.
#
###############################################################################

class Chef
  module EY
    class Environment
      RUBY_REGEXP = /^(j?ruby(?!gems)|ree)/

      def initialize(node)
        @node = node
        @hash = @node['dna']['engineyard']['environment']
      end

      def instances
        # TBD: Should these instances be of class Chef::EY::Instance or just the raw dna?
        @hash['instances']
      end

      def framework_env
        @hash['framework_env']
      end

      def component?(name)
        @hash['components'].any? { |c| c['key'] == name.to_s }
      end

      def component(name)
        @hash['components'].detect { |c| c['key'] == name.to_s }
      end

      def components
        @hash['components'] || Hash.new()  # CC-148 - Chef 0.10.9 fix
      end

      # Support a more natural way of accessing hash members and components
      def respond_to?(method)
        # @hash.key? method is broken so check keys list
        ([method, method.to_s] - @hash.keys).length < 2 || component?(method.to_s) || super
      end

      def method_missing(method, *args)
        respond_to?(method) ? (@hash[method] || @hash[method.to_s] || component?(method.to_s) || super) : super
      end

      def metadata(key = nil, default = nil)
        unless @component_metadata
          @component_metadata = component('environment_metadata').dup.reject { |k| k == 'key' }

          # Apply metadata that is applicable to this environment and remove all other
          @component_metadata.keys.select { |k| k.to_s.match(/^.*\[[^\]]*\]$/) }.each do |key|
            value = @component_metadata.delete(key)
            base, env_name = key.match(/^(.*)\[([^\]]*)\]$/)[1..2]
            @component_metadata[base] = value if env_name == self['name']
          end
        end
        key.nil? ? @component_metadata : @component_metadata.fetch(key.to_s, default)
      end

      def custom_ruby
        return @custom_ruby_version_str if @custom_ruby_version_checked
        v = metadata('ruby_version')
        v = "ruby-#{v}" unless v.nil? || v =~ RUBY_REGEXP
        @custom_ruby_version_checked = true
        @custom_ruby_version_str = v
      end

      def custom_ruby?
        !custom_ruby.nil?
      end

      def custom_rubygems
        metadata('rubygem_version')
      end

      def custom_rubymode
        metadata('ruby_mode')
      end

      def ruby?
        custom_ruby? ? custom_ruby =~ RUBY_REGEXP : @hash['components'].any? { |c| c['key'] =~ RUBY_REGEXP }
      end

      def jruby?
        custom_ruby? ? custom_ruby =~ /^jruby/ : @hash['components'].any? { |c| c['key'] =~ /^jruby/ }
      end

      def rubygems?
        @hash['components'].any? { |c| c['key'] =~ /^rubygems/ }
      end

      def lock_db_version?
        @hash['components'].any? { |c| c['key'] =~ /^lock_db_version/ }
      end

      def app_servers
        instances.select { |i| i['role'] =~ /^app/ }
      end

      def app_private_hostnames
        app_servers.map { |i| i['private_hostname'] }
      end

      def ruby
        return @ruby_component if @ruby_component
        if component = @hash['components'].detect { |c| c['key'] =~ RUBY_REGEXP }
          key = component['key'].to_sym
          r = ruby_package_details(
            custom_ruby     || default_ruby_version(key),
            custom_rubymode || default_ruby_mode(key)
          )

          # Rubygems should use the value specified in rubies method if present, otherwise use DNApi value
          r[:rubygems] = '1.4.2' if r[:full_version] =~ /^ruby-1.8.6/
          r[:rubygems] = custom_rubygems unless custom_rubygems.nil?
          unless r.has_key?(:rubygems)
            r[:rubygems] = rubygems? ? components.find_all { |e| e['key'] == 'rubygems' }.first['version'] : nil
          end
          if r[:full_version] =~ /^ruby-2\.0\./ and r[:rubygems] == '2.0.0'
            r[:rubygems] = '2.0.3'
          end
          @ruby_component = r
        end
      end

      def default_ruby_version(ruby_archtype)
        # According to
        # - https://support.cloud.engineyard.com/hc/en-us/articles/360022162773-Engine-Yard-Ubuntu-19-05-Technology-Stack
        # - https://support.engineyard.com/hc/en-us/articles/7598303972882-Stacks-compatibility-matrix
        versions = {
          :ruby_230 => "2.3.8",
          :ruby_240 => "2.4.10",
          :ruby_250 => "2.5.9",
          :ruby_260 => "2.6.7",
          :ruby_270 => "2.7.3",
          :ruby_300 => "3.0.1",
          :ruby_310 => "3.1.1"
        }
        if versions.has_key?(ruby_archtype.to_sym)
          version = versions[ruby_archtype.to_sym]
          return "#{ruby_archtype.to_s.sub(/_?[0-9]*$/, '')}-#{version}"
        else
          Chef::Log.fatal "Could not find a default version for ruby '#{ruby_archtype}'"
          exit(1)
        end
      end

      def default_ruby_mode(ruby_archtype)
        {
          :jruby_187 => 'RUBY1_8',
          :jruby_192 => 'RUBY1_9',
        }.fetch(ruby_archtype, nil)
      end

      def ruby_package_details(ruby_version, ruby_mode)
        {
          :full_version => ruby_version,
          :version      => ruby_version.split('-', 2).last,
        }.merge case ruby_version
                when /^jruby-.*/
                  ruby_mode ||= 'RUBY1_8' # defaults to 18
                  { :package => 'dev-java/jruby', :mode => ruby_mode }
                when /^ree-/
                  { :package => 'dev-lang/ruby-enterprise', :eselect_module => 'rubyee18' }
                when /^ruby-([0-9])\.([0-9]).*$/
                  { :package => 'dev-lang/ruby', :eselect_module => "ruby#{$1}#{$2}" }
                else
                  Chef::Log.fatal "Sorry, don't know how to handle ruby version #{ruby_version}"
                  exit(1)
                end
      end

      def db_adapter(app_type)
        if @hash['db_stack_name'] == 'mysql' && app_type == 'rack'
          'mysql2'
        else
          stack_name = @hash['db_stack_name'].gsub(/[^a-z]+/, '')
          # see https://tickets.engineyard.com/issue/DATA-66 to understand this
          case stack_name
          when 'aurora', 'mariadb', 'mysql'
            'mysql'
          when 'postgres', 'aurorapostgresql'
            'postgresql'
          else
            stack_name
          end
        end
      end

      def [](name)
        @hash[name]
      end
    end
  end
end
# AI-GEN END
