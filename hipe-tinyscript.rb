# minimal task running and command-line parsing.  no gem dependencies, only standard lib.
# colors, help screen generation

require 'optparse'

module Hipe
  module Tinyscript
    module Colorize
      Codes = {
        :bright=>'1', :red=>'31',     :green=>'32', :yellow=>'33',
        :blue=>'34',  :magenta=>'35', :bold=>'1',   :blink=>'5'
      }
      def colorize str, *codenames
        return str if codenames == [nil] || codenames.empty?
        codes = nil
        if codenames.first == :background
          fail("not yet") unless codenames.size == 2
          codes = ["4#{Codes[codenames.last][1..1]}"]
          # this isn't really excusable in any way
        else
          codes = codenames.map{|x| Codes[x]}
        end
        "\e["+codes.join(';')+"m#{str}\e[0m"
      end
      module_function :colorize
    end
    module Stringy
      def constantize name_sym
        name_sym.to_s.capitalize.gsub(/_([a-z])/){ "#{$1.upcase}" }
      end
    end
    class App
      include Colorize, Stringy
      class << self
        def config m=nil
          m.nil? ? @config : (@config = m)
        end
        def commands m=nil
          m.nil? ? @commands : (@commands = m)
        end
        def tasks m=nil
          m.nil? ? @tasks : (@tasks = m)
        end
      end
      def run argv
        this = self
        @argv = argv.dup
        @opts = {}
        parser = opt_parser
        status = nil
        begin
          status = catch(:interrupt) do
            parser.parse!(@argv)
            :ok
          end
          send status if :ok != status
        rescue OptionParser::ParseError => e
          out e.message
          out usage_string
        end
        run_command if status == :ok
      end
    protected
      alias_method :out, :puts
      def banner
        colorize('usage:', :bright, :green) << " #{File.basename(__FILE__)} [opts] [#{commands.map(&:short_name).join('|')}] -- [cmd opts]"
      end
      def build_parser
        opts = @opts
        this = self
        parser = OptionParser.new do |p|
          p.banner = this.banner
          opts[:verbose] = true

          p.on('-v', '--verbose', 'show more information'){ opts[:verbose] = true }

          p.on('-h', '--help', 'this screen'){ throw(:interrupt, :help) }

          opts[:do_it] = true
          p.on('-n', '--no-op', 'dry run (noop) -- just show what you would do, not do it') do
            opts[:do_it] = false
          end
        end
        parser
      end
      def commands
        @commands ||= begin
          mod = self.class.commands
          mod.constants.map{ |c| mod.const_get(c) }
        end
      end
      def config
        @config ||= begin
          self.class.config
        end
      end
      def tasks
        @tasks ||= begin
          mod = self.class.tasks
          mod.constants.map{ |c| mod.const_get(c) }
        end
      end
      def help
        out usage_string
      end
      def opt_parser
        @opt_parser ||= build_parser
      end
      def run_command
        if @argv.empty?
          out "Please indicate a command."
          out banner
        else
          command_str = @argv.shift
          re = Regexp.new("^#{Regexp.escape(command_str)}")
          cmds = commands.select{ |c| re =~ c.short_name }
          case cmds.size
          when 0
            out "#{command_str.inspect} is not a valid command."
            out banner
          when 1
            cmd = cmds.first
            if command_str != cmd.short_name
              out colorize("running: ", :bright, :green) << cmd.short_name
            end
            use_opts = config.dup
            use_opts[:args] = @argv.dup
            @opts.each{ |k,v| use_opts[k.to_sym] = v } # stringify keys
            cmd.new.run use_opts
          else
            out "#{command_str.inspect} is an ambiguous command."
            out "did you mean #{cmds.map{|x| %{"#{x.short_name}"}}.join(' or ')}?"
            out banner
          end
        end
      end
      def usage_string
        opt_parser.to_s
      end
    end

    class Command
      class << self
        def short_name
          to_s.match(/([^:]+)$/)[1].gsub(/([a-z])([A-Z])/){ "#{$1}-#{$2}" }.downcase
        end
        def tasks *tasks
          if tasks.any?
            @tasks = tasks
          else
            @tasks
          end
        end
      end
      alias_method :out, :puts
      def run opts
        @opts = opts
        populate_tasks!
        if parse_more_options
          @tasks.each{ |t| t.run }
        end
      end
    private
      def aggregate_option_defs
        @aod ||= begin
          defs = []
          @tasks.each{ |t| t.aggregate_option_definitions(defs) }
          defs
        end
      end
      def long_to_var_name long
        long.match(/^--([^ =]+)/)[1].gsub('-','_')
      end
      def parse_more_options
        parse_template_variables_in_options &&
        complain_of_missing_template_variables
      end
      # suk, didn't want to pass app around
      def task_map
        @task_map ||= begin
          md = self.class.to_s.match(/^(.+)::Commands::[^:]+$/) or fail("this just isn't going to work out")
          t = "#{md[1]}::Tasks".split('::').inject(Object){ |m, n| m.const_get n }
          ModuleTaskMap.new t
        end
      end
      def option_parser
        @option_parser ||= begin
          p = OptionParser.new
          p.banner = "usage: #{short_name} [options]"
          option_defs = aggregate_option_defs
          option_defs.each do |defn|
            var_name = long_to_var_name(defn[1])
            p.on(*defn.compact) do |value|  # compact is necessary. we have nil for first arg. no good
              @opts[var_name.to_sym] = value
            end
          end
          p
        end
      end
      # this is guaranteed to cause problems when tasks are more than just templates
      # it effectively requires that all options are provided
      def complain_of_missing_template_variables
        vars = aggregate_option_defs.map{ |x| long_to_var_name(x[1]) }
        missing = vars.select{ |x| ! @opts.key?(x.to_sym) }
        if missing.any?
          if missing.size == 1
            out "please provide a value for #{missing.first.inspect}"
          else
            out "please provide values for #{missing.join(', ')}"
          end
          out option_parser.to_s
          return false
        else
          return true
        end
      end
      def parse_template_variables_in_options
        begin
          option_parser.parse!(@opts[:args]);
        rescue OptionParser::ParseError => e
          out e.message
          out option_parser.to_s
          return false
        end
        return true
      end
      def populate_tasks!
        tasks = self.class.tasks
        @tasks = Array.new(tasks.size)
        tasks.each_with_index do |sym, idx|
          @tasks[idx] = task_map.build_task(sym, @opts)
        end
      end
      def short_name
        self.class.short_name
      end
    end

    class ModuleTaskMap
      include Stringy
      def initialize mod
        @module = mod
      end
      def build_task name_sym, opts
        const_name = constantize name_sym
        if ! @module.const_defined? const_name
          fail("task not found: #{const_name.inspect}")
        end
        cls = @module.const_get const_name
        obj = cls.new opts
        obj
      end
    end

    class Task
      include Colorize
      class << self
        def depends *foo
          @depends ||= []
          if foo.any?
            @depends.concat foo
            nil
          else
            @depends
          end
        end
        def use_template name
          @template_names ||= []
          @template_names.push name
        end
        def opts *names
          @opts ||= []
          if names.any?
            @opts.concat names
            nil
          else
            @opts
          end
        end
        def template_names
          @template_names ||= []
        end
      end
      def initialize opts
        @opts = opts
      end
      alias_method :out, :puts
      def aggregate_option_definitions defs
        my_names = []
        templates.each{ |t| my_names.concat t.variable_names }
        my_names.concat self.class.opts.map{ |x| x.to_s }
        my_names.each do |name|
          defs.push([ nil, "--#{name.gsub('_','-')} VALUE", String, name.gsub('_',' ') ])
        end
      end
      def task_name
        self.class.to_s.match(/::([^:]+)$/)[1].gsub( /([a-z])([A-Z])/ ){ "#{$1}_#{$2}" }.downcase.to_sym
      end
      def run
        out running_message
      end
      def running_message
        "running #{colorize(task_name.to_s, :magenta)}"
      end
    private
      def dry_run?
        ! @opts[:do_it]
      end
      def opt name
        fail("required option not found: #{name.inspect}") unless @opts.key?(name)
        @opts[name]
      end
      def run_dependees
        exit_status = nil
        if self.class.depends.any?
          self.class.depends.each do |name|
            t = task_map.build_task name, @opts
            child_status = t.run
            if ! child_status.nil?
              exit_status = child_status
              out "failed to run #{t.task_name} - child status: #{child_status.inspect}"
              break
            end
          end
        end
        exit_status
      end
      def task_map
        @task_map ||= begin
          md = self.class.to_s.match(/^(.+::Tasks)::[^:]+$/) or fail("blah blah")
          TaskMap.new md[1].split('::').inject(Object){ |m,n| m.const_get(n) }
        end
      end
      def templates
        @templates ||= {}
        self.class.template_names.map{ |name| @templates[name] ||= Template.build_template(@opts, name) }
      end
      def template
        @template ||= Hash.new{ |h,k| h[k] = templates.detect{ |t| t.name == k } }
      end
    end

    # common support classes to be used by clients

    module FileyCoyote
      include Colorize
      def update_file_contents path, contents
        if File.exist? path
          c1 = File.read(path)
          if (c1 == contents)
            out colorize('no change: ', :blue) << " #{path}"
            :no_change
          else
            out colorize('overwriting: ',:yellow) << " #{path}"
            File.open(path, 'w'){ |fh| fh.write(contents) } unless dry_run?
            :update
          end
        else
          out colorize('creating: ', :green) << "#{path}"
          File.open(path, 'w'){ |fh| fh.write(contents) } unless dry_run?
          :create
        end
      end
    end

    class Template
      class << self
        def build_template opts, name
          a = opts[:script_root_absolute_path] or fail("need :script_root_absolute_path in opts to build template")
          b = opts[:templates_directory] or fail("need :template_directory in opts to build template")
          abs_path = File.join(a,b,name)
          File.exist?(abs_path) or fail("template file not found: #{abs_path}")
          Template.new(abs_path, name)
        end
      end
      def initialize abs_path, name=nil
        if name
          fail("template file not found: #{abs_path}") unless File.exist?(abs_path)
          @abs_path = abs_path
          @name = name
        else
          @content = abs_path # terrible
        end
      end
      def interpolate vars
        fail_on_missing_var_names vars
        binding = put_vars_in_binding vars
        erb = ERB.new(content)
        return erb.result(binding)
      end
      attr_reader :name
      RE1 = /<%= *([a-zA-Z_][a-zA-Z0-9_]*) *%>/
      def variable_names
        @vn ||= begin
          if @content
            @content.scan(RE1).map{ |m| m[0] }.uniq
          else
            names = []
            File.open(@abs_path, 'r') do |fh|
              while line = fh.gets
                line.scan(RE1).map{ |m| names.push(m[0]) unless names.include?(m[0]) }
              end
            end
            names
          end
        end
      end
    private
      def content
        @content ? @content : File.read(@abs_path)
      end
      def fail_on_missing_var_names vars
        missing = variable_names.select{ |n| ! vars.key?(n.to_sym) }
        if missing.any? then fail("variables not set: #{missing.join(', ')}") end
      end
      def put_vars_in_binding vars
        b = Proc.new(){vars;}.binding
        variable_names.each do |name|
          eval("#{name} = vars[:#{name}]", b)
        end
        b
      end
    end
  end
end
