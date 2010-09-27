# Hipe::Tinyscript::
#
#                                                         ,-depends-
#                                                        /          `|
#   +--------------+     +----------------+     +---------------+    |
#   | App          |---<>| Command        |---<>| Task          | <-/
#   +--------------+     +----------------+     +---------------+
#                            |   |                            |
#                            |   |    +-----------------+     |
#                            |   |--<>| Parameter Def   |<>---+
#                            |        +-----------------+
#                        +----------------+    +----------------+
#                        | ParameterSet   |--<>| Parameter      |
#                        +----------------+    +----------------+
#
# minimal task running and command-line parsing.  no gem dependencies, only standard lib.
# colors, help screen generation.
# this differs from the 8 things before it
#   (GetOpt::Long, OptionParser, Hipe::CLI, Hipe::OptParseLite, Hipe::Interfacey, Trollip, Thor, Rake)
# in that it has tasks with dependencies and parameter-level help screen generation,
# with less reliance on DSL and more on classes and modules, because it's easier and clearer

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
      def sentence_join arr
        return nil if arr.empty?
        [arr[0], *(1..arr.size-1).map do |i|
          (/[.?!]$/ =~ arr[i-1] ? '  ' : '.  ') +
          (arr[i].sub(/^([a-z])/){$1.upcase})
        end
        ].join('')
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
      attr_accessor :program_name
      def run argv
        self.program_name ||= File.basename($0, '.*') # get this now before it changes
        @argv = argv.dup
        @opts = {}
        parser = option_parser
        status = nil
        begin
          status = catch(:interrupt){ parser.parse!(@argv); :ok }
          send(status.shift, *status) if :ok != status
        rescue OptionParser::ParseError => e
          out e.message
          out invite_to_more_help_message
        end
        run_command if status == :ok
      end
    protected
      alias_method :out, :puts
      def usage_string
        colorize('usage:', :bright, :green) << " #{program_name} [opts] {#{commands.map(&:short_name).join('|')}} -- [cmd opts]"
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
      def help
        out option_parser_help_string
        out invite_to_more_help_message
      end
      def on_invalid_paramter
        out invite_to_more_help_message
      end
      def invite_to_more_help_message
        "try " << colorize("#{program_name} <command_name> -- -h", :green) <<
          " for more help."
      end
      # app
      def option_parser
        @option_parser ||= begin
          opts = @opts
          this = self
          # this will have to change one day @todo
          OptionParser.new do |p|
            p.program_name = this.program_name # not used to generate banner but whatever
            p.banner = this.usage_string
            opts[:verbose] = true
            p.on('-v', '--verbose', 'show more information'){ opts[:verbose] = true }
            p.on('-h', '--help', 'this screen'){ throw :interrupt, [:help] }
            opts[:do_it] = true
            p.on('-n', '--no-op', 'dry run (noop) -- just show what you would do, not do it') do
              opts[:do_it] = false
            end
          end
        end
      end
      def run_command
        if @argv.empty?
          out "Please indicate a command."
          out usage_string
        else
          command_str = @argv.shift
          re = Regexp.new("^#{Regexp.escape(command_str)}")
          cmds = commands.select{ |c| re =~ c.short_name }
          if cmds.size > 1 && (c2 = cmds.detect{ |c| c.short_name == command_str })
            cmds = [c2]
          end
          case cmds.size
          when 0
            out "#{command_str.inspect} is not a valid command."
            out usage_string
          when 1
            cmd = cmds.first
            if command_str != cmd.short_name
              out colorize("running command: ", :bright, :green) << cmd.short_name
            end
            use_opts = config.dup
            use_opts[:args] = @argv.dup
            @opts.each{ |k,v| use_opts[k.to_sym] = v } # stringify keys
            cmd.new.run use_opts
          else
            out "#{command_str.inspect} is an ambiguous command."
            out "did you mean #{cmds.map{|x| %{"#{x.short_name}"}}.join(' or ')}?"
            out usage_string
          end
        end
      end
      def option_parser_help_string
        option_parser.help
      end
    end

    module DefinesParameters
      def parameter first, *rest, &block
        @parameter_definitions ||= []
        defn = [first, *rest]
        defn.push block if block
        @parameter_definitions.push defn
        nil
      end
      def parameter_definitions
        if @parameter_definitions
          @parameter_definitions.dup
        elsif ancestors[1].respond_to?(:parameter_definitions)
          ancestors[1].parameter_definitions
        else
          []
        end
      end
    end

    class Command
      include Colorize
      extend DefinesParameters
      class << self
        def description str=nil
          if str.nil?
            if @description
              @description
            elsif ancestors[1].respond_to?(:description)
              ancestors[1].description
            else
              []
            end
          else
            @description ||= []
            @description.push(str)
          end
        end
        def usage str=nil
          if str.nil?
            if @usage
              @usage
            elsif ancestors[1].respond_to?(:usage)
              ancestors[1].usage
            else
              []
            end
          else
            @usage ||= []
            @usage.push(str)
          end
        end
        def short_name
          to_s.match(/[^:]+$/)[0].gsub(/([a-z])([A-Z])/){ "#{$1}-#{$2}" }.downcase
        end
        def tasks *tasks
          fail("don't know") if @task_syms
          @task_syms = tasks
        end
        def task_names
          @task_syms ||= []
        end
      end
      alias_method :out, :puts
      def run opts
        out running_message
        @opts = opts
        status = nil
        parse_options && complain_on_missing_required && task_instances.each do |t|
          out colorize('task:', :green) << " #{t.short_name}"
          if status = t.run
            out "got error status from #{t.short_name}: #{status.inspect}"
            break
          end
        end
        if status
          out 'see above errors.'
        else
          out 'done.'
        end
        status
      end
      def short_name
        self.class.short_name
      end
    protected
      def invalid_argument param, val, err
        out err
        out command_help_invite
        false
      end
    private
      def complain_on_missing_required
        missing = parameter_set.parameters.select{ |p| ! @opts.key?(p.normalized_name) }
        case missing.size
        when 0
          true
        when 1
          out "please provide a value for #{missing.first.long}"
          out command_help_invite
          false
        else
          out "please provide values for #{missing.map(&:long).join(', ')}"
          out command_help_invite
          false
        end
      end
      def command_help_invite
        please_try = "#{short_name} -- -h"
        "please try #{colorize(please_try, :green)} for more help"
      end
      def description_lines
        description_lines = []
        if self.class.description.any?
          if self.class.description.size > 1
            description_lines.push colorize('description:', :bright, :green)
            description_lines.concat self.class.description
          else
            description_lines.push colorize('description: ', :bright, :green) <<
              self.class.description.first
          end
        end
        description_lines
      end
      # command
      def option_parser
        if ! @option_parser
          parser = OptionParser.new
          banner_lines = []
          banner_lines.concat description_lines
          banner_lines.concat usage_lines
          banner_lines.push colorize('options:', :bright, :green) if parameter_definitions.any?
          parser.banner = banner_lines.join("\n")
          parameter_set.each_parameter do |param|
            if param.block
              block = block
            elsif param.validate
              block = proc do |val|
                if (err = param.validate.call(val))
                  throw :interrupt, [:invalid_argument, param, val, err]
                else
                  @opts[param.normalized_name] = val
                end
              end
            else
              block = proc{ |v| @opts[param.normalized_name] = v }
            end
            defn = param.mixed_definition_array.dup.concat(param.description_lines) # prettier in 1.9
            parser.on(*defn, &block)
          end
          @option_parser = parser
        end
        @option_parser
      end
      def parameter_definitions
        if ! @parameter_definitions
          defs = self.class.parameter_definitions.dup
          task_instances.each{ |task| defs.concat task.parameter_definitions }
          @parameter_definitions = defs
        end
        @parameter_definitions
      end
      def parameter_set
        if ! @parameter_set
          params = ParameterSet.new
          parameter_definitions.each do |defn|
            params.merge_in_option_definition(*defn)
          end
          @parameter_set = params
        end
        @parameter_set
      end
      def parse_options
        begin
          status = catch(:interrupt){ option_parser.parse!(@opts[:args]); :ok }
          return self.send(status.shift, *status) unless :ok == status
          return true
        rescue OptionParser::ParseError => e
          out e.message
          out command_help_invite
          return false
        end
      end
      def running_message
        colorize('running command:',:bright, :green) <<'  '<< colorize(short_name, :magenta)
      end
      # suk, didn't want to pass app around
      def task_map
        @task_map ||= begin
          md = self.class.to_s.match(/^(.+)::Commands::[^:]+$/) or fail("this just isn't working out")
          t = "#{md[1]}::Tasks".split('::').inject(Object){ |m, n| m.const_get n }
          ModuleTaskMap.new t
        end
      end
      def usage_lines
        usage_title = colorize('usage:',:bright, :green)
        usage_lines = []
        if self.class.usage.any?
          if self.class.usage.size == 1
            usage_lines.push "#{usage_title} #{self.class.usage.first}"
          else
            usage_lines.push usage_title
            usage_lines.concat self.class.usage.map{ |l| "  #{l}" }
          end
        else
          tox = [short_name]
          if parameter_definitions.any?
            tox.push '[options]'
          end
          usage_lines.push "#{usage_title} #{tox.join(' ')}"
        end
        usage_lines
      end
      def task_instances
        @task_instances ||= begin
          self.class.task_names.map do |sym|
            task_map.build_task(sym, @opts)
          end
        end
      end
    end

    class ModuleTaskMap
      include Stringy
      def initialize mod
        @module = mod
      end
      def tasks name=nil
        these = @module.constants.map{ |const| @module.const_get const }
        if name
          re = Regexp.new(/^#{Regexp.escape(name)}/)
          found = these.select{ |t| re =~ t.short_name }
          one = found.detect{ |t| t.short_name == name }
          found = [one] if one
          these = found
        end
        these
      end
      def get_task_class name_sym
        const_name = constantize name_sym
        if ! @module.const_defined? const_name
          fail("task not found: #{const_name.inspect}")
        end
        @module.const_get const_name
      end
      def build_task name_sym, opts
        get_task_class(name_sym).build_task(opts)
      end
    end

    class ValidationUnion
      include Stringy
      def initialize a, b
        @list = [a, b]
      end
      attr_reader :list
      def push val
        @list.push val
      end
      def call value
        sentence_join( @list.map{ |v| v.call(value) }.compact )
      end
    end

    # abstract representation of all kinds of parameters
    class Parameter
      def initialize first, *rest
        defn = [first, *rest]
        @block = defn.last.kind_of?(Proc) ? defn.pop : nil
        @required = false
        nomalized_name = nil
        if defn.first.class == Symbol
          @normalized_name = defn.shift
          defn.unshift String
          defn.unshift "#{long} VALUE"
        elsif longlike = defn[0..1].detect{ |str| str.kind_of?(String) && /^--[a-z0-9][-a-z0-9_]+/i =~ str }
          @normalized_name = (/^--([a-z0-9][-_a-z0-9]+)/i).match(longlike)[1].gsub('-','_').to_sym
        else
          fail("couldn't figure out normalized name from #{defn.inspect}")
        end
        if defn.last.kind_of?(Hash)
          if defn.last[:validate]
            fail("can't have both block and validation") if block
            @validate = defn.last.delete(:validate)
          end
          if defn.last.key?(:required)
            @required = defn.last.delete(:required)
          end
          if defn.last.empty?
            defn.pop
          else
            fail("for now, we don't like these keys: #{defn.last.keys.map(&:to_s).join(', ')}")
          end
        end
        @desc = []
        @defn = []
        defn.each{ |x| (x.kind_of?(String) && /^[^-=]/ =~ x) ? @desc.push(x) : @defn.push(x) }
      end
      attr_reader :block, :defn, :desc, :normalized_name, :validate, :required
      alias_method :sym, :normalized_name
      alias_method :mixed_definition_array, :defn
      alias_method :description_lines, :desc
      alias_method :required?, :required
      def long
        "--#{normalized_name.to_s.gsub('_','-')}"
      end
      def merge_in_and_destroy_paramter param
        fail("won't merge #{param.sym.inspect} into #{sym.inspect} -- must have same name") unless
          @normalized_name == param.sym
        param.instance_variable_set('@normalized_name', nil)
        defn = param.instance_variable_get('@defn')
        if @defn.any? || defn.any?
          if @defn.any? && defn.any?
            fail("won't merge defnintion arrays") unless @defn == defn
          elsif defn.any?
            @defn = defn
            param.instance_variable_set('@defn', nil)
          end
        end
        desc = param.instance_variable_get('@desc')
        @required = param.required? if param.required? # see how that works?
        vald = param.instance_variable_get('@validate')
        @desc.concat desc
        @desc = @desc.uniq if @desc.any?
        param.instance_variable_set('@desc', nil)
        if (vald && @validate != vald)
          if @validate.nil?
            @validate = vald
          elsif @validate.kind_of?(ValidationUnion)
            @validate.push(vald) unless @validate.list.include?(vald)
          else
            @validate = ValidationUnion.new(@validate, vald)
          end
          param.instance_variable_set('@validate', nil)
        end
      end
    end
    class ParameterSet
      def initialize
        @parameters = {}
        @order = []
      end
      def merge_in_option_definition *defn
        newbie = Parameter.new(*defn)
        if @parameters.key?(newbie.normalized_name)
          @parameters[newbie.normalized_name].merge_in_and_destroy_paramter(newbie)
        else
          @parameters[newbie.normalized_name] = newbie
          @order.push newbie.normalized_name
        end
      end
      def each_parameter
        @order.each do |name|
          yield @parameters[name]
        end
      end
      def parameters
        @order.map{ |n| @parameters[n] }
      end
    end

    # these are tasks
    # life is simplier with only long option names for tasks
    class Task
      include Colorize
      extend DefinesParameters
      @@lock = {}
      class << self
        def build_task opts
          new opts
        end
        def depends *foo
          @dependee_names ||= []
          @dependee_names.concat foo
          nil
        end
        def dependee_names
          @dependee_names ||= []
        end
        def short_name
          to_s.match(/[^:]+$/)[0].gsub(/([a-z])([A-Z])/){ "#{$1}_#{$2}" }.downcase
        end
        def template_names
          @template_names ||= []
        end
        def use_template name
          @template_names ||= []
          @template_names.push name
        end
      end
      def initialize opts
        @opts = opts
      end
      alias_method :out, :puts
      def parameter_definitions
        if ! @parameter_definitions
          defs = self.class.parameter_definitions.dup
          templates.each do |t|
            t.variable_names.each do |n|
              defs.push( [n.to_sym, "for #{t.short_name} *",{ :required => true } ] )
            end
          end
          with_each_dependee_object_safe{ |o| defs.concat o.parameter_definitions }
          @parameter_definitions = defs
        end
        @parameter_definitions
      end
      def run
        out running_message
      end
      def running_message
        "running #{colorize(short_name, :magenta)}"
      end
      def short_name
        self.class.short_name
      end
    private
      def dry_run?
        ! @opts[:do_it]
      end
      def get_dependee_object task_name
        @dependee_objects ||= Hash.new{ |h, k| task_map.get_task_class(k).build_task(@opts) }
        @dependee_objects[task_name]
      end
      def opt name
        fail("required option not found: #{name.inspect}") unless @opts.key?(name)
        @opts[name]
      end
      def run_dependees
        exit_status = nil
        with_each_dependee_object_safe do |dependee|
          exit_status = dependee.run
          if ! exit_status.nil?
            out "failed to run #{dependee.short_name} - child status: #{exit_status.inspect}"
            break
          end
        end
        exit_status
      end
      def task_map
        @task_map ||= begin
          md = self.class.to_s.match(/^(.+::Tasks)::[^:]+$/) or fail("blah blah")
          ModuleTaskMap.new md[1].split('::').inject(Object){ |m,n| m.const_get(n) }
        end
      end
      def templates
        @templates ||= begin
          self.class.template_names.map{ |name| Template.build_template(@opts, name) }
        end
      end
      def template
        @template ||= Hash.new{ |h,k| h[k] = templates.detect{ |t| t.name == k } }
      end
      def with_each_dependee_object_safe &block
        self.class.dependee_names.each do |task_name|
          if @@lock[task_name]
            fail("circular dependency detected: #{task_name.inspect} is already being run while trying to run itself")
          else
            @@lock[task_name] = short_name # i have a lock on you
            task = get_dependee_object task_name
            begin
              yield task
            ensure
              @@lock[task_name] = false
            end
          end
        end
        nil
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
      alias_method :short_name, :name
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

    module Commands
      #
      # if the client wants a command that's just for running one specific task
      # (usually for debu-gging), still sloppy
      #
      class TaskCommand < Command
        description "run one specific task"
        parameter '-l', '--list', 'list all known tasks'
        usage "task -- {these opts}"
        usage "task <task_name> -- [task opts]"

        def invite; "try #{colorize('task -- -h',:green)} for more help" end
        def run opts
          @opts = opts
          if @opts[:args].empty?
            out "no <task_name> and no {-h|-l}"
            out usage_lines
            out invite
          elsif /^-/ =~ @opts[:args].first
            if parse_options
              if @opts[:list] || true
                task_map.tasks.each{ |t| out t.short_name }
              end
            end
          else
            task_name = @opts[:args].shift
            tasks = task_map.tasks(task_name)
            case tasks.size
            when 0
              out "no task #{task_name.inspect} found.  Available tasks: "<<
                task_map.tasks.map(&:short_name).sort.join(', ')
              out usage_lines
            when 1
              run_task tasks.first
            else
              out "no task #{task_name.inspect} found."
              out "did you mean #{tasks.map(&:short_name).join(' or ')}?"
              out.usage_lines
            end
            nil
          end
        end
        def run_task task_class
          @option_parser = nil
          @parameter_definitions = []
          @task_instances = [task_class.build_task(@opts)]
          if parse_options
            t = task_class.build_task(@opts)
            exit = t.run
            if exit
              puts "got problematic status from #{t.short_name}: #{exit.inspect}"
            else
              puts "done with #{t.short_name}"
            end
          else
            if @parameter_definitions.any?
              out @option_parser.help
            end
          end
        end
      end
    end
  end
end
