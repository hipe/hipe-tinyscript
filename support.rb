# depends: 'hipe-tinyscript.rb'
require 'erb'
require 'rexml/document'

module Hipe::Tinyscript::Support
  #
  # support classes and modules used by more than one command line script
  #

  Colorize = ::Hipe::Tinyscript::Colorize # re-established here with extensions
  Stringy = ::Hipe::Tinyscript::Stringy
  Table = ::Hipe::Tinyscript::Table

  class ConfFile
    # Stupid simple parsing of stupid simple config files (like those for thin)
    # Warning: the location of this class here may be temporary while we find a home for it

    def initialize
      @attr = nil
      @order = []
      @generated_fields = [:basename]
      yield self
    end
    attr_accessor :valid_fields, :generated_fields
    def basename
      File.basename(@path)
    end
    def parse_file path
      fail("can't parse fail if i already have attributes") if @attr # if u don't do this, think about path
      @path = path
      File.open(path, 'r') do |fh|
        line_number = 0
        while line = fh.gets
          line.chomp!
          line_number += 1
          case line
          when /\A[[:space:]]*([a-z_]+)[[:space:]]*:[[:space:]]*(.*)\z/; parse_attribute($1, $2.strip)
          when /\A[[:space:]]*#/;    # ignore lines with comments
          when /\A[[:space:]]*\z/;   # ignore blank linkes
          when /\A---.*\z/;          # todo what are these?
          else; add_error("unable to parse at line #{line_number}: #{line}")
          end
        end
      end
    end
    def add_error msg
      @error_messages ||= []
      @error_messages.push msg
    end
    def validate
      @error_messages ? @error_messages.join(' ') : (@attr.nil? ?  "conf file is empty" : nil)
    end
    def value name_str
      if @attr.key?(name_str)
        @attr[name_str]
      elsif @generated_fields.include?(name_str.to_sym)
        send name_str.to_sym
      else
        nil
      end
    end
  private
    def parse_attribute name_str, val
      if @attr && @attr.key?(name_str)
        add_error "#{name_str.inspect} attribute assigned a value multiple times (#{@attr[name_str].inspect}, #{val.inspect})"
        add_attribute name_str, val
        false
      elsif @valid_fields && ! @valid_fields.include?(name_str)
        add_error "#{name_str.inspect} is not in the list of known fields."
        add_attribute name_str, val
        false
      else
        add_attribute name_str, val
        true
      end
    end
    def add_attribute name_str, val
       @attr ||= {}
       @order.push name_str
       @attr[name_str] = val
    end
  end

  class ClosedStruct
    #
    # like OpenStruct but the opposite.  Make an object that quacks like a hash:
    # its public instance methods (getter-like) are callable by the [] method.
    # Useful for templates when you want to define the set of variables not with a hash
    # but with a bunch of procs
    #

    def initialize opts=nil
      opts && opts.each{ |name, proc| define(name, &proc) }
    end
    def key? foo
      respond_to? foo
    end
    def [] foo
      send foo
    end
    def define name, &block
      singleton_class.send(:define_method, name, &block)
    end
    def singleton_class
      class << self; self end
    end
  end

  module EpeenStruct
    # Sorta like the getter from OpenStruct: less magic, less efficient
    class << self
      def extended foo
        class << foo; self end.send(:include, self)
        foo
      end
      def [] mixed
        mixed.extend self
      end
    end
    def method_missing k
      self.key?(k) ? self[k] : super(k)
    end
  end

  class Fieldset
    # can be used in conjunction with tableize / Table, but doesn't have to be
    def initialize *a
      @fields = a.each_with_index.map{ |x,i| Field.new(x,i,self) }
    end
    class << self
      def [](*a)
        Fieldset.new(*a)
      end
    end
    [:each, :map, :select].each do |meth|
      define_method(meth){ |*a, &b| @fields.send(meth, *a, &b) }
    end
    def deep_dup
      self.class.new(* @fields)
    end
  end

  class Field
    def initialize mixed, idx, parent
      @visible = true
      @index = idx
      @align = :right # a good default for both numbers and filenames with the same extension
      case mixed
      when Field; deep_dup_init! mixed
      when Symbol; @id = mixed
      when Array; init_with_args! mixed
      else fail("can't build a field from #{mixed.inspect} -- need symbol or other field")
      end
      class << self; self end.send(:define_method, :parent){ parent } # memoize for cleaner dumps
    end
    attr_reader :align, :index, :id, :visible
    attr_writer :align
    alias_method :visible?, :visible
    def hidden?; ! @visible end
    def hide!; @visible = false end
    def show!; @visible = true end

    extend Hipe::Tinyscript::Stringy # clever way to do the below
    [:humanize, :titleize].each{ |m| define_method(m){ self.class.send(m, @id) } }

    def printf_format width
      minus = (@align == :left) ? '-' : ''
      "%#{minus}#{width}s"
    end

  private
    def deep_dup_init! field
      %w(@align @id @visible).each{ |attr| instance_variable_set attr, field.instance_variable_get(attr) }
    end
    def init_with_args! arr
      [Symbol, Hash] == arr.map(&:class) or
        raise ArgumentError.new("expecting [Symbol, Hash] not #{arr.join(&:class).inspect}")
      @id = arr[0]
      arr[1].each{ |k, v| send("#{k}=", v) }
    end
  end

  module FileyCoyote
    # common file operations done in scripts
    include Colorize
    Macros = {
      :basename => proc{ |path| File.basename(path) },
      :dirname  => proc{ |path| File.dirname(path) },
      :readable_timestamp => proc{ |path| Time.now.strftime('%Y-%m-%d-%H-%M-%S') }
    }
    def make_backup path, template='<%= dirname %>/<%= basename %>.<%= readable_timestamp %>.bak'
      params = {}
      template.scan(/\<%= *([^ %]+) *%>/).each do |name,|
        prok = Macros[name.to_sym] or fail("macro not found: #{name.inspect}") # one day etc
        params[name.to_sym] = prok.call(path)
      end
      tgtpath = Template.new(template).interpolate(params)
      fail("aw hell no") if File.exist?(tgtpath)
      FileUtils.cp(path, tgtpath, :verbose => true, :noop => dry_run?)
      tgtpath
    end
    def update_file_contents path, contents, opts = nil
      opts = {:p => false}.merge(opts || {})
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
        dir = File.dirname(path)
        if ! File.exist?(dir)
          if opts[:p]
            FileUtils.mkdir_p(dir, :verbose => true, :noop => dry_run?)
          else
            fail("won't create directories here: directory doesn't exist: #{dir}")
          end
        end
        out colorize('creating: ', :bright, :green) << " #{path}"
        File.open(path, 'w'){ |fh| fh.write(contents) } unless dry_run?
        :create
      end
    end
  end

  class GitRepo
    # warning this might get moved

    include Colorize, FileyCoyote
    def initialize agent, local_path, remote_url
      @ui = agent
      @abs_path = local_path
      @remote_url = remote_url
    end
    attr_reader :abs_path, :remote_url
    def clone
      fail("won't clone: path exists: #{abs_path}") if path_exists?
      fail("won't clone: is already a repo: #{abs_path}") if is_repo?
      cmd = "git clone #{remote_url} #{abs_path}"
      @ui.out colorize('git cloning:', :bright, :green) << " #{cmd}"
      if @ui.dry_run?
        :dry
      else
        foo = ''; bar = nil; status = nil
        Open3.popen3(cmd) do |sin, sout, serr|
          while foo || bar do
            if foo && foo = sout.gets
              @ui.out foo
            end
            if ! foo && bar = serr.gets
              @ui.out(colorize("failed to git clone:", :bright, :red) <<" #{bar.inspect}")
              status = :git_problems
            end
          end
        end
        @ui.out(colorize("git cloned!", :blink, :bright, :green)) if status.nil?
        status
      end
    end
    def path_exists?
      File.exist? @abs_path
    end
    def is_repo?
      File.exist? File.join(@abs_path, '.git')
    end
  end

  class Mysql
    # hacky as all getout basic wrapper around the commandline mysql client

    include Colorize

    # set connection params now or lazily in block with set_params!
    def initialize agent, user=nil, pass=nil, database=nil, &block
      @ui = agent
      if user.kind_of?(Hash)
        fail("no!") unless block.nil? && pass.nil? && database.nil?
        set_params! user
      elsif block
        fail("no!") unless user.nil? && pass.nil?
        @database = database # secret hack
        @block = block
      else
        set_params!( 'username' => user, 'password' => pass, 'database' => database )
      end
    end
    def database
      connection! unless (@database or @connection)
      @database # no reason to expect it was necessarily set.
    end
    attr_reader :database
    attr_writer :password
    def execute_sql_file file
      fail("no") unless File.exist?(file)
      pw = @password ? " --password=#{@password}" : ''
      cmd = "mysql -u #{@username}#{pw} #{@database} < #{file}"
      @ui.out cmd
      unless @ui.dry_run?
        %x{#{cmd}}
      end
    end
    def sql_xml sql
      fail("please don't make me deal with escaping single quotes: #{sql.inspect}") if sql.index("'")
      connection! unless @connection
      pw = @password ? " --password=#{@password}" : ''
      cmd = "mysql -u #{@username}#{pw} -X #{@database} -e '#{sql}'"  # you want single not double for backticks
      %x{#{cmd}}
    end
    def sql_xml_doc sql
      xml = sql_xml sql
      '' == xml ? nil : REXML::Document.new(xml)
    end
    def dumps dirpath=nil
      Dir[File.join(dirpath, "dump-#{@database}-*.sql")]
    end
    def report_dumps dumps
      one = dumps.size == 1
      @ui.out colorize("exist#{'s' if one}:", :blue) << " dump#{'s' unless one}: #{dumps.join(', ')}"
    end
    DefaultDumpTimeFormat = '%Y-%m-%d-%H-%M-%S'
    def dump dirpath
      now = Time.now.strftime(DefaultDumpTimeFormat)
      outpath = File.join(dirpath, "dump-#{@database}-#{now}.sql")
      cmd = "mysqldump -u #{@username} -p#{@password} --opt --debug-check -r #{outpath} #{@database}"
      @ui.out colorize('executing:',:green) << " #{cmd}"
      status = nil
      unless @ui.dry_run?
        Open3.popen3(cmd) do |sin, sout, serr|
          foo = ''; bar = nil;
          while foo || bar do
            @ui.out foo if foo && foo = sout.gets
            if !foo && bar=serr.gets
              @ui.out colorize('error: ',:red) << " #{bar}"
              status = :mysqldump_errors
            end
          end
        end
      end
      status
    end
    def run sql
      @ui.out colorize('sql:', :yellow) << " #{sql}"
      unless @ui.dry_run?
        xml = sql_xml sql
        fail("not expected #{xml.inspect}") if '' != xml
      end
      nil
    end
    def one_or_more_exists? sql
      doc = sql_xml_doc(sql) or fail("sql problems")
      found = doc.root.elements[1].elements['//field'].text
      fail("positive integer expected, had #{found.inspect}") unless (/^\d+$/ =~ found)
      amt = found.to_i
      amt >= 1
    end
    def one_not_zero_exists? sql
      doc = sql_xml_doc(sql) or fail("sql problems")
      case found = doc.root.elements[1].elements['//field'].text
      when '1'; true
      when '0'; false
      else; fail("expecting zero or one had #{found.inspect} from query: #{sql}")
      end
    end
    def set_params! params
      fail("careful!") if @username or @password or @connection
      @username = params['username'] or fail("missing 'username' element")
      @database = params['database'] if params['database']
      @password = params['password'] # nil ok
      @connection = true
    end
  private
    def connection!
      fail("strict!") if @connection
      fail("no block was provided for lazy connection") unless @block
      @block.call(self)
      fail("block did not create connection") unless @connection
      nil
    end
  end

  module Stringy
    class AboutTimeNow
      class << self
        def singleton; @singleton ||= new end
      end
      def now?; true end
    end
    class AboutTime < AboutTimeNow
      def initialize unit, amt, future, fmt='%d'
        @unit, @amt, @future, @fmt = [unit, amt, future, fmt]
      end
      attr_accessor :future
      alias_method :future?, :future
      def amount
        @fmt % (('%d' == @fmt) ? @amt.round : @amt)
      end
      def now?; false end
      def units_inflected
        "#{@unit.to_s}#{amount == 1 ? '' : 's'}"
      end
    end
    def about_time seconds_float, now_float = Time.now.to_f
      d = about_time_data seconds_float, now_float
      d.now? ? "now" :  "#{d.amount} #{d.units_inflected} #{d.future? ? 'from now' : 'ago'}"
    end
    SecMin = 60.0
    SecHour = SecMin * 60.0
    SecDay = SecHour * 24.0
    FiftyFiveMinutes = 55.0 * SecMin
    TwentyThreeHours = 23.0 * SecHour
    def about_time_data instance_time_float, now_time_float
      abs = (instance_time_float - now_time_float).abs
      future = instance_time_float > now_time_float
      case abs
      when 0.0; return AboutTimeNow.singleton
      when (0.0...1.0) ; return AboutTime.new(:second, abs, future, '%0.6f')
      when (1.0...55.0) ; return AboutTime.new(:second, abs, future)
      when (55.0...FiftyFiveMinutes) ; return AboutTime.new(:minute, abs / SecMin, future)
      when (FiftyFiveMinutes...TwentyThreeHours) ; return AboutTime.new(:hour, abs / SecHour, future)
      else ; return AboutTime.new(:day, abs / SecDay, future)
      end
    end
  end

  class SvnWorkingCopy
    include Colorize
    def initialize agent, path, repo_url=nil, repo_revision=nil
      @ui = agent
      @create_parent_dir = false
      @abs_path = path
      @repo_url = repo_url
      @repo_revision = repo_revision
    end
    attr_reader :repo_revision, :abs_path, :repo_url
    def create_if_necessary!
      ret = nil
      if path_exists?
        @ui.out colorize('exists: ',:blue) << abs_path
        if ! is_repo?
          @ui.out colorize('SUCK', :bright, :red) << " exists but is not repo: #{abs_path}"
          ret = :exists_but_is_not_repo
        end
      else
        empty_dir = File.dirname(abs_path)
        if ! File.directory?(empty_dir)
          if @create_parent_dir
            FileUtils.mkdir_p(empty_di, :verbose => true, :noop => @ui.dry_run?)
          else
            @ui.out "containing directory must exist"
            return :parent_directory_does_not_exist
          end
        end
        if ! @repo_revision
          @ui.out "won't do svn checkout withot a revision number"
          ret = :no_revision_number
        else
          cmd = "svn co #{repo_url}@#{repo_revision} #{abs_path}"
          @ui.out colorize("attempting svn checkout:", :bright, :green) << " #{cmd}"
          if ! @ui.dry_run?
            ret = run_svn_command cmd
          end
        end
      end
      ret
    end
    def is_repo?
      File.exist? File.join(@abs_path, '.svn')
    end
    def create_parent_dir!
      @create_parent_dir = true
    end
    def path_exists?
      File.exist? @abs_path
    end
    def revision
      rev_str = nil
      Open3.popen3("svn info #{@abs_path}") do |sin, sout, serr|
        errs = '', outs = ''
        begin
          unless errs.nil?
            errs = serr.gets
            fail("got error: #{errs}") if errs
          end
          unless outs.nil?
            outs = sout.gets
            if outs && /^Revision: (\d+)$/ =~ outs
              rev_str = $1
              break
            end
          end
        end until errs.nil? && outs.nil?
      end
      rev_str
    end
    def status_lines_parsed letters=nil
      thing = letters.nil? ? '[^ ]+' : ('[' << letters.map{ |x| Regexp.escape(x) }.join << ']')
      re = Regexp.new("^(#{thing}*) +(.+)$")
      status_lines.map{ |x| md = re.match(x) and { :type => md[1], :path => md[2] } }.compact
    end
    def status_paths letters=nil
      status_lines_parsed(letters).map{ |x| x[:path] }
    end
    def status_lines
      lines = nil
      FileUtils.cd(@abs_path) do |x|
        Open3.popen3("svn status .") do |sin, sout, serr|
          err = serr.read
          fail("can't svn status: #{err.inspect}") unless err == ''
          lines = sout.read.split("\n")
        end
      end
      lines
    end
  private
    def run_svn_command cmd
      status = nil
      foo = ''; bar = nil
      Open3.popen3(cmd) do |sin, sout, serr|
        while foo || bar do
          @ui.out(foo) if foo && foo = sout.gets
          if ! foo && bar = serr.gets
            @ui.out color('svn error:', :red) << " #{bar}"
            fail = :svn_io_fail
          end
        end
      end
      status
    end
  end

  class Template
    # generic ERB templates with reflection and validation
    class << self
      def build_template opts, name
        opts.key?(:template_directory) or fail("need :template_directory in opts to build template")
        abs_path = File.join(opts[:template_directory], name)
        File.exist?(abs_path) or fail("template file not found: #{abs_path}")
        self.new(abs_path, name)
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
    # a module that contains pre-built commands that many client apps may want to use

    class TaskCommand < ::Hipe::Tinyscript::Command
      description "run one specific task (usually just for debuggins)"
      parameter '-l', '--list', 'list all known tasks'
      parameter '-p', '--dependencies', 'additionally, list dependees of each task'
      parameter '-s', '--descriptions', 'additionally, list descriptions of each task'
      usage "task {-l[-p][-s]|-h}"
      usage "task <task_name> [task opts]"

      def parse_opts argv
        if @super or argv.any? && /^-/ =~ argv.first
          super(argv)
        else
          true
        end
      end

      def parse_argv argv
        case argv.size
        when 0
          if argv.size == 0 && @param[:list]
            true # fallthrough
          else
            out "Expecting <task_name> had #{argv.size} arguments."
            out usage_lines
            out command_help_invite
            false
          end
        else
          task_name = argv.shift
          tasks = task_context.tasks(task_name)
          case tasks.size
          when 0
            out "no task #{task_name.inspect} found.  Available tasks: "<<
              task_context.tasks.map(&:short_name).sort.join(', ')
            out usage_lines
            out command_help_invite
            false
          when 1
            @task_to_run = tasks.first
            @reparse_argv = argv.dup
            argv.clear
            true
          else
            out "no task #{task_name.inspect} found."
            out "did you mean #{tasks.map(&:short_name).join(' or ')}?"
            out.usage_lines
            out command_help_invite
            false
          end
        end
      end

      def redef foo, &bar
        class << self; self end.send(:define_method, foo, &bar)
      end

      def execute
        if @super
          super
        elsif @param[:list]
          redef(:on_success){ nil }
          tasks = task_context.tasks.sort{|x, y| x.short_name <=> y.short_name}
          if @param.key?(:dependencies) || @param.key?(:descriptions)
            show_with_extra tasks
          else
            tasks.each{ |t| out t.short_name }
          end
          nil
        else
          ## you've gotta run() again but this time with different parameter definitions
          @option_parser = @parameter_set = @task_instances = nil
          @task_ids = [@task_to_run.normalized_name]
          redef(:parameter_definitions){ task_instances.first.parameter_definitions }
          (foo = "#{invocation_name} #{@task_to_run.short_name}") && redef(:invocation_name){ foo }
          redef(:description_lines){ [] }
          redef(:usage_lines){ [colorize('task meta info:', :bright, :green) << ' ' << colorize(@task_to_run.short_name, :green)] }
          redef(:parse_argv){ true }
          @reparse_argv.unshift(short_name)
          @super = true
          run @param, @reparse_argv
        end
      end

      def show_with_extra tasks
        des = @param.key? :descriptions
        dep = @param.key? :dependencies
        matrix = tasks.map do |t|
          [ t.short_name,
            dep ? (t.dependee_names.any? ? ("-> {" << t.dependee_names.join(', ') << "}") : '') : nil,
            des ? (t.description ? t.description.first : '') : nil
          ].compact
        end
        tableize(matrix) do |t|
          fmt = (0..t.num_cols-1).map{ |i| "%-#{t.width(i)}s"}.join(' ')
          t.rows{ |*c| out sprintf(fmt, *c) }
        end
      end
    end
  end
  class Table
    class << self
      def smart_sort_matrix! matrix, column_ids, sort
        t = new(matrix){ |_| _.column_ids = column_ids }
        t.smart_sort! sort
        nil
      end
    end
    attr_reader :column_ids
    def column_ids= arr
      @column_ids = arr
      @idx = Hash[* arr.each_with_index.to_a.flatten ]
    end
    def smart_sort! sort, column_ids=nil
      self.column_ids = column_ids unless column_ids.nil?
      fail("no smart sort without column ids first!") unless @idx
      if (no = sort.select{ |pair| ! @idx.key?(pair[0])}.map{|x| x[0]}).any?
        fail("the field ids in your sort selection are not known: #{no.map(&:inspect) * ' '}")
      end
      infer_column_types! unless @column_types_inferred
      @rows.sort! do |a, b|
        col_idx = nil
        # find the first index of the sort list that has cels that are not equal
        found = sort.detect{ |pair| col_idx = @idx[pair[0]]; a[col_idx] != b[col_idx] }
        return 0 unless found # no cels are not equal so all relevant fields of both sides are equal
        # we have who hahs that are not equal.  the scalar who hah of these two will determine order
        send "compare_as_#{@types[col_idx]}", found[1], a[col_idx], b[col_idx]
      end
      nil
    end
  private
    def compare_as_float asc_desc, val_a, val_b
      (val_a.to_f <=> val_b.to_f) * ((asc_desc == :asc) ? 1 : -1)
    end
    def compare_as_int asc_desc, val_a, val_b
      (val_a.to_i <=> val_b.to_i) * ((asc_desc == :asc) ? 1 : -1)
    end
    def compare_as_string asc_desc, val_a, val_b
      (val_a <=> val_b)           * ((asc_desc == :asc) ? 1 : -1)
    end
    def infer_column_types!
      @types = Array.new(@rows.map(&:size).max, :unknown)
      @rows.each do |row|
        row.each_with_index do |val, idx|
          this_type = case val
          when /\A[-+]?\d+\.\d+\z/; :float
          when /\A[-+]?\d+\z/;      :int
          when /\A[[:space:]]*\z/;  :blank
          else                      :string
          end
          old_type = @types[idx]
          new_type = (this_type == :string) ? :string : case old_type
          when this_type;           old_type
          when :blank;              this_type
          when :string;             :string
          when :unknown;            this_type
          when :int;
            case this_type
            when :float;            :float
            when :blank;            :string
            else fail("nevar: #{old_type.inspect} to #{this_type.inspect}")
            end
          when :float;
            case this_type
            when :blank;            :string
            when :int;              :float
            else fail("nevar: #{old_type.inspect} to #{this_type.inspect}")
            end
          else fail("nevar: #{old_type.inspect} to #{this_type.inspect}")
          end
          @types[idx] = new_type
        end
      end
      @column_types_inferred = true
    end
  end
end
