# hipe tinyscript 0.0.1
#
# minimal task running and command-line parsing.  no gem dependencies, only standard lib.
#
# colors, help screen generation.
#
# this differs from, builds on or trys to improve beyond the 8 things before it
#   (GetOpt::Long, OptionParser, Hipe::CLI, Hipe::OptParseLite, Hipe::Interfacey, Trollip, Thor, Rake)
#
# like rake, handles a dependency graph of tasks.  unlike rake, more helpful help screens
# and paramter parsing.
#
# less reliance on DSL and more on classes and modules, because it's clearer and more modularizable
#
#
# Hipe::Tinyscript::
#
#                                                         ,-depends-
#                                                        /          `|
#   +--------------+     +----------------+     +---------------+    |
#   | App          |---<>| Command        |---<>| Task          | <-/
#   +--------------+     +----------------+     +---------------+
#                            |   |                                \
#                            |   |    +----------------------+     |
#                            |   |--<>| parameter definition |<>--+
#                            |        +---------------------+
#   ##----- (internal below) ----------------------------------------------##
#                            |
#                            |
#                        +----------------+    +----------------+
#                        | ParameterSet   |--<>| Parameter      |
#                        +----------------+    +----------------+
#
#
# both tasks and commands stipulate parameter definitions. an app is made of
# many commands, which *can* be made of many tasks. tasks can depend on other tasks. (circular
# dependencies should bark.)  Internally, the command object aggregates all the parameter
# definitions from all the tasks (definitions can even merge where multiple tasks use parameters
# with the same name but different descriptions.).  The command is responsible for turning
# the ARGV stream into a parsed options hash, and the tasks all run using this same hash.
#
#
# changes: 0.0.1 - positional arguments with parsing, @param not @opts

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
    module FuzzyMatch
      def fuzzy_match enum, needle, method=nil, &block
        if method
          fail("no") if block
          block = proc{ |x| x.send(method) }
        end
        hard = enum.detect{ |item| block.call(item) == needle } and return [hard]
        re = Regexp.new("\\A#{Regexp.escape(needle)}")
        enum.select{ |item| re =~ block.call(item) }
      end
    end
    module Stringy
      def constantize name_sym
        name_sym.to_s.capitalize.gsub(/_([a-z])/){ "#{$1.upcase}" }
      end
      def humanize mixed
        case mixed.to_s
        when /_/; mixed.to_s.gsub('_', ' ')
        when /[a-z][A-Z]/; mixed.to_s.gsub(/([a-z])([A-Z])/){ "#{$1} #{$2.downcase}" }
        else mixed.to_s
        end
      end
      def titleize mixed
        humanize(mixed).gsub(/^([a-z])/){ $1.upcase }
      end
      def num2ord_short fixnum
        ((1..3).include?(fixnum.abs % 10) && ! (11..13).include?(fixnum.abs % 100)) ?
          "#{fixnum}#{ {1=>'st', 2=>'nd', 3=>'rd'}[fixnum.abs % 10]  }" : "#{fixnum}th"
      end
      def oxford_join a, last=' and ', comma=', '
        a.zip((2..a.size).map{ |i| i == a.size ? last : comma }).flatten.join('')
      end
      def sentence_join arr
        return nil if arr.empty? # important
        [arr[0], *(1..arr.size-1).map do |i|
          (/[.?!]$/ =~ arr[i-1] ? '  ' : '.  ') +
          (arr[i].sub(/^([a-z])/){$1.upcase})
        end
        ].join('')
      end
      def tableize matrix, &block
        Table.new(matrix, &block)
      end
    end
    class Table
      # matrix cels should be strings
      def initialize matrix
        @rows = matrix
        yield self if block_given? && matrix.any?
      end
      def num_cols
        @num_cols ||= @rows.map{ |r| r.size }.max || 0
      end
      def width idx
        @widths || calculate_column_widths!
        @widths[idx]
      end
      def rows
        @rows.each{ |row| yield(*row) } if block_given?
        @rows
      end
      def calculate_column_widths!
        @widths ||= []
        @widths.clear
        @rows.each do |row|
          row.each_with_index do |val, idx|
            @widths[idx] = val.length unless ! @widths[idx].nil? && @widths[idx] > val.length
          end
        end
        nil
      end
    end
    module ParameterAccessor
      def param name
        fail("expected parameter not set: #{name.inspect}") unless @param.key?(name)
        @param[name]
      end
    end
    module ParentClass
      def parent_class
        ancestors[1..-1].detect{ |x| x.class == ::Class }
      end
    end
    module DefinesParameters
      include ParentClass
      #
      # This must be used by modules, not objects (for now. only b/c of ancestors())
      #
      # As of yet, parameter definitions can be added, and added to,
      # but they cannot yet be taken away
      # Child classes inheirit parent class parameter definitions.
      # Commands may or may not inheirit parameter definitions from the app?
      # At the processing level (where parameter objects are made) maybe there will
      # be options to 'undefine' a parameter that a parent class defines

      def parameter first, *rest, &block
        defn = [first, *rest]
        defn.push block if block
        @parameter_definitions ||= []
        @parameter_definitions.push defn
        nil
      end

      # for now, grab all from parent class too
      def parameter_definitions
        defs = nil # always return a dup, not your original array
        if parent_class.respond_to?(:parameter_definitions)
          defs = parent_class.parameter_definitions
          defs.concat(@parameter_definitions) if @parameter_definitions
        elsif @parameter_definitions
          defs = @parameter_definitions.dup
        else
          defs = []
        end
        defs
      end
    end
    module UiMethods
      class << self
        def included cls
          cls.send(:alias_method, :out, :puts) # def out
          cls.send(:public, :out)
        end
      end
      def dry_run?; @param[:dry_run] end
      def err *a
        $stderr.puts(*a)
      end
      def errs
        $stderr
      end
      def outs
        $stdout
      end
    end

    class Command
      include ParameterAccessor, Colorize, Stringy, UiMethods
      extend DefinesParameters

      # we could etc
      parameter('-h', '--help', 'this screen'){ throw :command_interrupt, [:show_command_help] }

      @@last_index = -1

      class << self
        def desc_oneline
          return description.first if description.any?
          return usage.first if usage.any?
          "usage: #{documenting_instance.usage_string_generated}"
        end
        def description str=nil
          if str.nil?
            if @description
              @description
            elsif parent_class.respond_to?(:description)
              parent_class.description
            else
              []
            end
          else
            @description ||= []
            @description.push(str)
          end
        end
        alias_method :documenting_instance, :new
        attr_accessor :index # set when class is loaded
        def inherited subclass
          subclass.index = @@last_index += 1
        end
        def short_name
          to_s.match(/[^:]+$/)[0].gsub(/([a-z])([A-Z])/){ "#{$1}-#{$2}" }.downcase
        end
        alias_method :syntaxy_name, :short_name
        def subcommands mod=nil
          if mod.nil?
            @subcommands
          elsif @subcommands
            fail("never")
          else
            include SuperCommand
            @subcommands = mod
            pim = public_instance_methods(false).map(&:to_sym)
            SuperCommand.public_instance_methods.each do |meth| # hack rewrite methods!
              meth = meth.to_s.match(/^supercommand_(.+)$/)[1].to_sym
              unless pim.include?(meth)
                alias_method "orig_#{meth}", meth
                alias_method meth, "supercommand_#{meth}"
              end
            end
          end
        end
        def tasks *tasks
          fail("don't know") if @task_ids
          @task_ids = tasks
        end
        def task_ids
          @task_ids && @task_ids.dup or []
        end
        def usage str=nil
          if str.nil?
            if @usage
              @usage
            elsif parent_class.respond_to?(:usage)
              parent_class.usage
            else
              []
            end
          else
            @usage ||= []
            @usage.push(str)
          end
        end
      end
      def command_running_message
        colorize('running command:',:bright, :green) <<' '<< colorize(short_name, :magenta)
      end
      def description_lines_enhanced
        return self.class.description if self.class.description.any?
        return self.class.usage if self.class.usage.any?
        return [ "usage: #{usage_string_generated}"] # [ "the #{short_name} command."]
      end
      def err *a
        $stderr.puts(*a)
      end
      def on_ambiguous_subcommand_resolved cmd_cls, name_used
        out cmd_cls.documenting_instance.command_running_message
        nil
      end
      def on_ambiguous_command_resolved
        out command_running_message
      end
      def on_missing_required_parameters missing
        out "please provide required parameter#{'s' if missing.size > 1}: #{missing.map(&:vernacular).join(', ')}"
        false
      end
      def on_unexpected_arguments argv
        out "unexpected argument#{'s' if argv.size > 1}: #{argv.map(&:inspect).join(', ')}"
        false
      end
      def on_success
        out 'done.'
        nil
      end
      def on_failure status
        # you don't want these, everthing should have reported errors by now!
        # out command_help_invite
        # out colorize(invocation_name, :green) << " completed with the above error(s)."
        status
      end
      def parameter_validation_fail param, val, err
        puts "validation failure for #{param.vernacular}: #{err}"
        puts command_help_invite
        false; # to get parse_opts to return error status
      end
      def run opts, argv
        argv = argv.dup
        opts = opts.dup
        on_ambiguous_command_resolved unless argv.shift == short_name
        @param = opts # sorry this is thrown around both as a parameter and member variable
        status = parse_opts(argv) && parse_argv(argv) && defaults(opts) && complain(opts, argv) && execute() # sexy
        status.nil? ? on_success : on_failure(status)
      end
      def short_name
        self.class.short_name # ''note2''
      end
      alias_method :syntaxy_name, :short_name
    private # change to protected whenever
      def add_subcommands_to_parameter_set! mod
        fail("can't have positional arguments and subcommands") if @parameter_set.parameters.detect{ |p| p.positional? }
        param = SubCommands.new(mod, self) # @todo
        fail("can't have subcommands if you already have a #{param.name_symbol}") if @parameter_set.key?(param.name_symbol)
        @parameter_set[param.name_symbol] = param
        nil
      end
      def banner_string
        banner_lines = []
        banner_lines.concat description_lines
        banner_lines.concat usage_lines
        banner_lines.push colorize('options:', :bright, :green) if parameter_definitions.any?
        banner_lines.join("\n")
      end
      def build_option_parser
        OptionParser.new do |parser|
          parser.banner = banner_string
          parameter_set.parameters.select{ |p| p.enabled? && ! p.positional? }.each do |param|
            block =
              if param.block
                # evaluate the block passed in the context of the command, but when the option parser
                # parses it
                command = self
                proc{ |val| command.instance_exec(val, &(param.block)) }
              elsif param.validate
                proc do |val|
                  if (err = param.validate.call(val))
                    throw :command_interrupt, [:parameter_validation_fail, param, val, err]
                  else
                    @param[param.normalized_name] = val
                  end
                end
              else
                proc{ |v| @param[param.normalized_name] = v }
              end
            defn = param.mixed_definition_array.dup.concat(param.description_lines_enhanced) # prettier in 1.9
            parser.on(*defn, &block)
          end
        end
      end
      def complain opts, argv
        missing = parameter_set.parameters.select{ |p| p.enabled? && p.required? && ! opts.key?(p.normalized_name) }
        miss_ok = ! missing.any? || on_missing_required_parameters(missing)
        have_ok = ! argv.any?    || on_unexpected_arguments(argv)
        everything_ok = (miss_ok && have_ok)
        everything_ok || out(command_help_invite)
        everything_ok
      end
      def command_help_invite
        "please try " << colorize("#{invocation_name} -h", :green) << " for more help."
      end
      alias_method :invocation_name, :short_name
      def defaults opts
        ps = parameter_set.parameters.select{ |p| p.has_default? && ! opts.key?(p.normalized_name) }
        ps.each{ |p| opts[p.normalized_name] = p.default_value }
        true
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
      def option_parser
        @option_parser ||= build_option_parser
      end
      def parameter_definitions
        if ! @cipd
          defs = self.class.parameter_definitions
          task_instances.each{ |task| defs.concat task.parameter_definitions }
          @cipd = defs
        end
        @cipd.dup
      end
      def parameter_set
        if ! @parameter_set
          @parameter_set = ParameterSet.new(parameter_definitions)
          add_subcommands_to_parameter_set!(self.class.subcommands) if self.class.subcommands
        end
        @parameter_set
      end
      def parse_argv argv
        positionals = parameter_set.parameters.select{ |x| x.positional? && x.enabled? }
        positional_syntax_check(positionals) if positionals.any? # run it every time i guess
        ret = true
        while positionals.any? and argv.any?
          param = positionals.shift
          value = argv.shift.dup # changes the frozen status of this thing so validation can change it!
          if err = param.validate_with_definition(value, @param)
            out err
            ret = false
          elsif param.block
            param.block.call(value) # i have trouble imagining if this would ever be useful but maybe
          elsif param.validate
            if err = param.validate.call(value, @param)
              out err
              ret = false
            else
              @param[param.normalized_name] = value
            end
          else
            @param[param.normalized_name] = value
          end
        end
        out command_help_invite unless ret
        ret
      end
      def parse_opts argv
        begin
          status = catch(:command_interrupt){ option_parser.parse!(argv); :ok }
          return self.send(status.shift, *status) unless :ok == status
          return true
        rescue OptionParser::ParseError => e
          out e.message
          out command_help_invite
          return false
        end
      end
      def positional_syntax_check positionals
        opt0 = positionals.index{ |x| ! x.required? }
        req0 = positionals.index{ |x| x.required? }
        if opt0 && req0
          req1 = positionals.reverse.index{ |x| x.required? }
          # we could parse many more complex syntaxes ala ruby 1.9 globs but this is easiest
          unless req1 < opt0
            fail("Syntax Syntax fail: last required at #{req1} must be before first optional at #{opt0}")
          end
        end
      end
      # this is the default implementation for execute() too
      def run_dependees
        status = nil
        task_instances.each do |t|
          out colorize('task:', :green) << " #{t.short_name}"
          if status = t.smart_run
            out colorize('task:', :green) << " #{t.short_name} " << colorize('failed:',:red) << " #{status.inspect}"
            break
          end
        end
        status
      end
      alias_method :execute, :run_dependees # def execute
      FIXME = 1
      def show_command_help
        out option_parser.help
        params = parameter_set.parameters.select{ |x| x.positional? && x.enabled? }
        if params.any?
          if params.size == 1 && params.last.kind_of?(SubCommands)
            params = params.last.classes.sort_by(&:index).map{ |cls| cls.documenting_instance }
            noun = 'sub-command'
          else
            noun = 'argument'
          end
          out colorize("#{noun}#{'s' if params.size > 1}:", :bright, :green)
          matrix = []
          params.each do |param|
            lines = param.description_lines_enhanced
            matrix.push [ param.syntaxy_name, lines.shift ]
            matrix.push [ '', lines.shift ] while lines.any?
          end
          tableize(matrix) do |t|
            whitespace = ' ' * (option_parser.summary_width - t.width(0) + FIXME)
            fmt = "    %#{t.width(0)}s#{whitespace}%-#{t.width(1)}s"
            t.rows{ |*cols| out sprintf(fmt, *cols) }
          end
        end
        false # get parse_opts to return false so no further processing is done! ick but whatever
      end
      # suk, didn't want to pass app around
      def task_context
        @task_context ||= begin
          md = self.class.to_s.match(/^(.+)::Commands::.+$/) or fail("this just isn't working out")
          ModuleTaskContext.for_module "#{md[1]}::Tasks".split('::').inject(Object){ |m, n| m.const_get n }
        end
      end
      def usage_lines
        usage_title = colorize('usage:', :bright, :green)
        usage_lines = []
        if self.class.usage.any?
          if self.class.usage.size == 1
            usage_lines.push "#{usage_title} #{self.class.usage.first}"
          else
            usage_lines.push usage_title
            usage_lines.concat self.class.usage.map{ |l| "  #{l}" }
          end
        else
          usage_lines.push "#{usage_title} #{usage_string_generated}"
        end
        usage_lines
      end
      def usage_string_generated
        [syntaxy_name, *usage_tokens].join(' ')
      end
      public :usage_string_generated
      # experimental
      def usage_tokens
        toks = []; opts = []; args = [];
        parameter_set.parameters.each do |p|
          next unless p.enabled?
          ( p.positional? ? args : opts ).push(p)
        end
        toks.concat opts.map{ |x| x.usage_string }
        toks.concat args.map{ |x| x.usage_string }
        toks
      end
      def task_ids
        @task_ids || self.class.task_ids
      end
      def task_instances
        unless @task_instances
          @task_instances = task_ids.map do |sym|
            task_context.get_task(sym, @param)
          end
        end
        @task_instances
      end
    end

    class App
      include Colorize, FuzzyMatch, Stringy, UiMethods
      extend ParentClass
      @subclasses = []
      class DefaultCommand < Command; end # defined right after the App class below
      @default_command_class = DefaultCommand

      class << self
        attr_accessor :program_name # must be settable by multiplexer
        attr_reader :subclasses
        # subclasses of App (and its subclasses) will have a usefull 'subclasses' method iff @subclasses is set.
        def inherited foo
          subclasses.push(foo) if subclasses
        end
        def config m=nil
          m.nil? ? @config : (@config = m)
        end
        def commands m=nil
          m.nil? ? @commands : (@commands = m)
        end
        def default_command_class cls=nil
          if cls.nil?
            if @default_command_class
              @default_command_class
            elsif parent_class.respond_to?(:default_command_class)
              parent_class.default_command_class
            else
              nil
            end
          else
            @default_command_class = cls
          end
        end
        def description str=nil
          str.nil? ? (@description ||= []) : (@description ||= []).push(str)
        end
        def tasks m=nil
          m.nil? ? @tasks : (@tasks = m)
        end
      end
      def initialize
      end
      def commands
        @commands ||= begin
          mod = self.class.commands
          mod.constants.map{ |c| mod.const_get(c) }
        end
      end
      def program_name
        @program_name || self.class.program_name
      end
      attr_writer :program_name
      alias_method :short_name, :program_name # for multiplexer
      def run argv
        @program_name = File.basename($0, '.*') unless program_name # could have been set by who knos
        argv = argv.dup # don't change anything passed to you
        response = nil
        interrupt = catch(:app_interrupt) do
          if argv.empty? || /^-/ =~ argv.first
            response = build_default_command.run config.dup, argv
          else
            response = find_command_and_run argv
          end
          :ok
        end
        :ok == interrupt ? response : send(interrupt.shift, *interrupt)
      end
      def show_command_specific_help command
        run [command, '--help']
      end
      def version
        self.class.const_defined?('Version') ? self.class.const_get('Version') : nil
      end
    protected
      def build_default_command
        self.class.default_command_class.new self
      end
      def config
        @config ||= begin
          self.class.config || {}
        end
      end
      # keep this here it is overridden and called up to from children
      def find_commands argv
        fuzzy_match commands, argv.first, :short_name
      end
      # you're guaranteed that argv has a first arg is a non-switch arg
      def find_command_and_run argv
        cmds = find_commands argv
        case cmds.size
        when 0
          out "#{argv.first.inspect} is not a valid command."
          out 'please try ' << colorize("#{program_name} -h", :bright, :green) << " for a list of valid commands."
        when 1
          run_command cmds.first, argv
        else
          out "#{argv.first.inspect} is an ambiguous command."
          out "did you mean #{cmds.map{|x| %{"#{x.short_name}"}}.join(' or ')}?"
          out build_default_command.invite_to_app_help
        end
      end
      def run_command cmd_class, argv
        cmd_class.new.run config.dup, argv
      end
    end

    class App::DefaultCommand < Command
      parameter('-v', '--version', 'shows version information' ){ throw :command_interrupt, [:show_app_version] }
      def initialize app
        @app = app
      end
      def invite_to_app_help
        "try " << colorize("#{@app.program_name} -h", :bright, :green) << " for help."
      end
      def run params, argv
        argv = argv.dup # never change, also note params are ignored
        status = parse_opts(argv)
        if :interrupt_handled == status
          # nothing
        elsif true == status
          out "please indicate a command."
          out invite_to_app_help
        else
          # error should have been displayed.
        end
      end
    private
      def build_option_parser
        unless @app.version
          parameter_set[:version].disable!
        end
        parameter_set[:help] = Parameter.new('-h', '--help [command]', 'this screen',
          Proc.new { |x| throw :command_interrupt, [:show_maybe_command_help, x] } # don't ask :(
        )
        op = super
        op.summary_width = 20
        op
      end
      def banner_string
        colorize('usage:', :bright, :green) <<
        "\n#{@app.program_name} [opt]\n"<<
        "#{@app.program_name} {#{@app.commands.map(&:short_name).join('|')}} [opts] [args]\n"<<
        colorize('app options:', :bright, :green)
      end
      def invocation_name
        @app.program_name
      end
      def show_app_version
        out "#{@app.program_name} #{@app.version}"
        :interrupt_handled
      end
      def show_maybe_command_help cmd=nil
        throw :app_interrupt, [:show_command_specific_help, cmd] unless cmd.nil? # just yes
        out option_parser.help
        matrix = []
        out colorize('commands:', :bright, :green)
        @app.commands.sort_by(&:index).each do |c|
          matrix.push [c.short_name, c.desc_oneline]
        end
        fmt = nil
        tableize(matrix) do |t|
          whitespace = ' ' *  (option_parser.summary_width - t.width(0) + FIXME)
          fmt = "    %#{t.width(0)}s#{whitespace}%-#{t.width(1)}s"
          t.rows{ |*cols| out sprintf(fmt, *cols) }
        end
        out "please try " << colorize("#{@app.program_name} <command> -h", :bright, :green) << " for command help."
        :interrupt_handled
      end
    end

    class ModuleTaskContext
      include FuzzyMatch
      @contexts = {}
      class << self
        attr_reader :contexts
        def for_module mod
          contexts[mod] ||= new mod
        end
      end
      include Stringy
      def initialize mod
        @cache = {}
        @module = mod
      end
      def tasks name=nil
        name.nil? ? @module.constants.map{ |const| @module.const_get const } : fuzzy_match(tasks, name, :short_name)
      end
      def get_task_class name_sym
        const_name = constantize name_sym
        if ! @module.const_defined? const_name
          fail("task not found: #{const_name.inspect}")
        end
        @module.const_get const_name
      end
      def get_task name_sym, opts
        fail("task name symbol is not symbol: #{name_sym.inspect}") unless name_sym.kind_of?(Symbol)
        if @cache.key? name_sym
          @cache[name_sym].new_opts!(opts)
          @cache[name_sym]
        elsif cls = get_task_class(name_sym)
          fail("#{cls.normalized_name.inspect} != #{name_sym.inspect}") unless cls.normalized_name == name_sym
          @cache[name_sym] = cls.build_task(opts)
        end
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
      include Stringy
      def initialize first, *rest
        defn = [first, *rest]
        @enabled = true
        @block = defn.last.kind_of?(Proc) ? defn.pop : nil
        @required = false
        nomalized_name = nil
        if defn.first.class == Symbol
          @normalized_name = defn.shift
          if defn.any? && ( ! defn.first.kind_of?(String) || /^-/ !~ defn.first )
            defn.unshift String #@todo what does this even mean ''here1''
            defn.unshift "#{name_to_long} VALUE"
          end
        elsif longlike = defn[0..1].detect{ |str| str.kind_of?(String) && /^--(?:\[no-\])?[a-z0-9][-a-z0-9_]+/i =~ str }
          @normalized_name = (/^--(?:\[no-\])?([a-z0-9][-_a-z0-9]+)/i).match(longlike)[1].gsub('-','_').to_sym
        else
          fail("couldn't figure out normalized name from #{defn.inspect}")
        end
        if defn.last.kind_of?(Hash)
          opts = defn.last
          if opts.key?(:default)
            @has_default = true
            default = opts.delete(:default)
            class << self; self end.send(:define_method, :default_value){ default } # don't ask, just being ridiculous
          end
          if opts[:validate]
            fail("can't have both block and validation") if block
            @validate = opts.delete(:validate)
          end
          @required = opts.delete(:required) if opts.key?(:required)
          @positional = opts.delete(:positional) if opts.key?(:positional)
          if opts.empty?
            defn.pop
          else
            fail("for now, we don't like these keys: #{opts.keys.map(&:to_s).join(', ')}")
          end
        end
        @desc = []
        @defn = []
        defn.each{ |x| (x.kind_of?(String) && /^[^-=]/ =~ x) ? @desc.push(x) : @defn.push(x) }
      end
      attr_reader :block, :defn, :desc, :enabled, :has_default, :normalized_name, :positional, :validate, :required
      alias_method :sym, :normalized_name
      alias_method :mixed_definition_array, :defn
      alias_method :description_lines, :desc
      alias_method :has_default?, :has_default
      alias_method :enabled?, :enabled
      alias_method :positional?, :positional
      alias_method :required?, :required
      # later we might support interpolation of a <%= default %> guy in there but for now quick and dirty
      def description_lines_enhanced
        hazh = @defn.detect{ |x| x.kind_of? Hash }
        return description_lines unless ( hazh || has_default? )
        lines = description_lines
        lines.push "{#{hazh.keys.sort.join('|')}}" if hazh
        if has_default?
          if lines.empty?
            lines.push ''
          else
            lines[lines.size - 1] = "#{lines[lines.size - 1]} " # we don't want to change the string in the definition structure
          end
          lines.last.concat "(default: #{default_value.inspect})"
        end
        lines
      end
      def disable!; @enabled = false end
      def enable!;  @enabled = true end
      def name_to_long
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
      def syntaxy_name
        normalized_name.to_s.gsub('_','-')
      end
      # wackland
      def usage_string
        if positional?
          required? ? "<#{syntaxy_name}>" : "[<#{syntaxy_name}>]"
        else
          longmun  = @defn.detect{ |x| x =~ /^--/ }
          shortmun = @defn.detect{ |x| x =~ /^-[^-]/ }
          if ! shortmun
            fug = longmun
          elsif /^[^ =]+([ =])(.+)$/ =~ longmun
            fug = "#{shortmun}#{$2}" # fduk
          else
            fug = shortmun
          end
          required? ? fug : "[#{fug}]"
        end
      end
      # this is only for positional arguments to validate sorta like OptParse flags do!!
      def validate_with_definition value, param
        sx = []
        @defn.select{ |x| ! x.kind_of?(String) }.each do |x|
          if String == x
            # ignore these, what even do they mean!? @todo''here1''
          elsif x.kind_of?(Hash)
            if x.key?(value)
              value.replace(x[value]) if x[value] != value
            else
              sx.push "#{vernacular} must be {#{x.keys.sort.join('|')}}, not #{value.inspect}"
            end
          else
            fail("not yet, maybe one day timmy: #{x.inspect}")
          end
        end
        sentence_join sx
      end
      def vernacular
        if positional?
          "<#{syntaxy_name}>"
        else
          these = @defn.select{ |x| x.kind_of?(String) }
          these.detect{ |x| /^--/ =~ x } || name_to_long # don't know if this would ever be necessary
        end
      end
    end
    module SuperCommand
      # while still allowing clients to use plain old commands, rewrite some of the Command methods! hack.
      # parse only the contiguous leading elements that start with a dash
      # you can't have supercommand options that take arguments unless they do it with '=' and no spaces!
      def supercommand_parse_opts argv
        if argv.empty? || argv.first =~ /^[^-]/
          true
        else
          if idx = argv.index{ |x| x =~ /^[^-]/ }
            left = argv.slice(0,idx)
            right = argv[idx..-1]
          else
            left = argv
            right = []
          end
          orig_parse_opts(left) or return false
          argv.replace [left, right].flatten
          true
        end
      end
      def supercommand_on_unexpected_arguments argv
        @argv_to_child = argv
        true # always ok
      end
      def supercommand_execute
        @argv_to_child ||= [] # when there were no extra arguments, above was not called
        @argv_to_child.unshift param(:_action) # the name used, not necessarily the same name
        param(:_subcommand_class).new.run @param, @argv_to_child
      end
      def supercommand_on_success
        nil # don't say "done." child does
      end
    end
    class SubCommands # quacks like a Parameter (a lot of quacking to do!)
      include FuzzyMatch, Stringy
      def initialize mod, cmd_instance
        @agent = cmd_instance
        @module = mod
      end
      def block;        nil      end
      def enabled?;     true     end
      def has_default?; false    end
      def name_symbol;  :_action end
      alias_method :normalized_name, :name_symbol
      def vernacular; "sub-command" end
      def validate;     nil      end
      def required?;    true     end
      def classes
        @module.constants.map{ |c| @module.const_get(c) }
      end
      def positional?;  true     end
      def usage_string
        these = classes.sort_by(&:index).map{ |x| x.syntaxy_name }.join('|')
        "{#{these}} [opts] [args]"
      end
      def validate_with_definition value, param
        found = fuzzy_match classes, value, :syntaxy_name
        msgs = []
        case found.size
        when 0
          msgs.push "invalid sub-command: #{value.inspect}"
          msgs.push "expecting: #{usage_string}"
        when 1
          param[:_subcommand_class] = found.first
        else
          msgs.push "#{value.inspect} is ambiguous. Did you mean " <<
            oxford_join(found.map(&:syntaxy_name), ' or ') << "?"
        end
        msgs.any? ? msgs.join("\n") : nil
      end
    end
    class ParameterSet
      def initialize defns=nil
        @parameters = {}
        @order = []
        defns.each do |defn|
          merge_in_parameter_definition(*defn)
        end if defns
      end
      def [] name_symbol
        @parameters[name_symbol]
      end
      def key? name_symbol
        @parameters.key? name_symbol
      end
      # use with extreme caution! only for hacking
      def []= name_symbol, thing
        @order.push(name_symbol) unless @order.include?(name_symbol)
        @parameters[name_symbol] = thing
      end
      def merge_in_parameter_definition *defn
        newbie = Parameter.new(*defn)
        if @parameters.key?(newbie.normalized_name)
          @parameters[newbie.normalized_name].merge_in_and_destroy_paramter(newbie)
        else
          @parameters[newbie.normalized_name] = newbie
          @order.push newbie.normalized_name
        end
      end
      def parameters
        @order.map{ |n| @parameters[n] }
      end
    end

    # these are tasks
    # life is simplier with only long option names for tasks
    class Task
      include Colorize, ParameterAccessor, Stringy, UiMethods
      extend DefinesParameters
      @@lock = {}
      class << self
        def build_task opts
          new opts
        end
        def depends_on *foo
          @dependee_names ||= []
          @dependee_names.concat foo
          nil
        end
        def dependee_names
          @dependee_names ||= []
        end
        def description str=nil
          if str.nil?
            @description ? @description.dup : nil
          else
            @description ||= []
            @description.push(str)
          end
        end
        def short_name
          to_s.match(/[^:]+$/)[0].gsub(/([a-z])([A-Z])/){ "#{$1}_#{$2}" }.downcase
        end
        def normalized_name
          short_name.to_sym
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
        @ran_times = 0
        @param = opts
      end
      def new_opts! opts
        if @param.object_id != opts.object_id
          fail("hate")
        end
      end
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
        @parameter_definitions.dup
      end
      def run
        if self.class.dependee_names.any?
          run_dependees
        else
          out colorize("implement me: ", :bright, :yellow) << ' ' << colorize(short_name, :magenta)
          :not_implemented
        end
      end
      def smart_run
        if @ran_times == 0 # if it's new just straight up run it
          @ran_times += 1
          @last_status = run
        elsif @last_status # if it's not new and the last time it ran there were errors, run again
          @ran_times += 1
          next_last_status = run
          out "tried task a #{num2ord_short(@ran_times)} time: " << colorize(short_name, :green) <<
           " was before: #{@last_status.inspect} just now: #{next_last_status}"
          @last_status = next_last_status
        else # skip it if it ran successfully before
          fail("never: #{@last_status.inspect}") unless @last_status.nil?
          out colorize('skpping:',:blue) << " already completed task: " << colorize(short_name, :green)
          @last_status # should be nil but whatever
        end
      end
      def task_running_message
        "running #{colorize(short_name, :magenta)}"
      end
      def short_name
        self.class.short_name # ''note2''
      end
    private
      def get_dependee_object task_id
        @dependee_objects ||= Hash.new{ |h, k| task_context.get_task(k, @param) }
        @dependee_objects[task_id]
      end
      def run_dependees *mixed
        exit_status = nil
        with_each_dependee_object_safe(*mixed) do |dependee|
          exit_status = dependee.smart_run
          if ! exit_status.nil?
            out "failed to run #{dependee.short_name} - child status: #{exit_status.inspect}"
            break
          end
        end
        exit_status
      end
      def task_context
        @task_context ||= begin
          md = self.class.to_s.match(/^(.+::Tasks)::[^:]+$/) or fail("blah blah")
          ModuleTaskContext.for_module md[1].split('::').inject(Object){ |m,n| m.const_get(n) }
        end
      end
      def templates
        @templates ||= begin
          self.class.template_names.map{ |name| ::Hipe::Tinyscript::Support::Template.build_template(@param, name) }
        end
      end
      def template
        @template ||= Hash.new{ |h,k| h[k] = templates.detect{ |t| t.name == k } }
      end
      def with_each_dependee_object_safe *args, &block
        names = (args.size==0) ? self.class.dependee_names :
          ((args.size == 1 && a.first.kind_of?(Array)) ? args.first : args)
        names.each do |task_id|
          if @@lock[task_id]
            fail("circular dependency detected: #{task_id.inspect} is already being run while trying to run itself")
          else
            @@lock[task_id] = short_name # i have a lock on you
            task = get_dependee_object task_id
            begin
              yield task
            ensure
              @@lock[task_id] = false
            end
          end
        end
        nil
      end
    end
  end
end
