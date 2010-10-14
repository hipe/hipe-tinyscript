# depends: 'hipe-tinyscript.rb'
require 'erb'
require 'rexml/document'

module Hipe::Tinyscript::Support
  #
  # support classes and modules used by many command line scripts
  #


  Colorize = ::Hipe::Tinyscript::Colorize

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
    #
    # Sorta the getter from OpenStruct: less magic, less efficient
    #

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

  # common support classes to be used by clients
  module FileyCoyote
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
    attr_reader :database
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
    def dumps
      Dir[File.join(@dirpath, "dump-#{@database}-*.sql")]
    end
    def report_dumps dumps
      one = dumps.size == 1
      @ui.out colorize("exist#{'s' if one}:", :blue) << " dump#{'s' unless one}: #{dumps.join(', ')}"
    end
    def dump dirpath
      @dirpath = dirpath
      if (dumps = self.dumps).any?
        @ui.out report_dumps(dumps)
        nil
      else
        if ! @connection
          connection!
          if (dumps = self.dumps).any?
            @ui.out report_dumps(dumps)
            return nil
          end
        end
        now = Time.now.strftime('%Y-%m-%d-%H-%M')
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
    end
    def do_sql sql
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


  # move to tinyscript-support
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
        puts colorize('exists: ',:blue) << abs_path
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
    #
    # generic ERB templates with reflection and validation
    #

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
    #
    # This module contains pre-built commands that many client apps may want to use
    #

    class TaskCommand < ::Hipe::Tinyscript::Command
      #
      # if the client wants a command that's just for running one specific task
      # (usually for debu-gging)
      #

      description "run one specific task"
      parameter '-l', '--list', 'list all known tasks'
      parameter '-d', '--dependencies', 'additionally, list dependees of each task'
      usage "task {-l[-d]|-h}"
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
          if @param[:dependencies]
            show_with_deps tasks
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

      def show_with_deps tasks
        matrix = []
        tasks.each do |t|
          if t.dependee_names.any?
            dependee_str =  "-> {" << t.dependee_names.join(', ') << "}"
          else
            dependee_str =  ''
          end
          matrix.push [ t.short_name, dependee_str ]
        end
        tableize(matrix) do |t|
          fmt = "%-#{t.width(0)}s  %-#{t.width(1)}s"
          t.rows{ |*c| out sprint(fmt, *c) }
        end
      end
    end
  end
end
