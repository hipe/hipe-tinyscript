# depends: 'hipe-tinyscript.rb'

module Hipe::Tinyscript::Support
  #
  # support classes and modules used by many command line scripts
  #


  Colorize = ::Hipe::Tinyscript::Colorize

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

  class GitRepo
    include Colorize, FileyCoyote
    def initialize local_path, remote_url
      @abs_path = local_path
      @remote_url = remote_url
    end
    attr_reader :abs_path, :remote_url
    def clone io
      fail("won't clone: path exists: #{abs_path}") if path_exists?
      fail("won't clone: is already a repo: #{abs_path}") if is_repo?
      cmd = "git clone #{remote_url} #{abs_path}"
      io.out colorize('git cloning:', :bright, :green) << " #{cmd}"
      if io.dry_run?
        :dry
      else
        foo = bar = ''; status = nil
        Open3.popen3(cmd) do |sin, sout, serr|
          while foo || bar do
            if foo && foo = sout.gets
              io.out foo
            end
            if bar && bar = serr.gets
              io.out(colorize("failed to git clone:", :bright, :red) <<" #{bar.inspect}")
              status = :git_problems
              break
            end
          end
        end
        io.out(colorize("git cloned!", :blink, :bright, :green)) if status.nil?
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
    def initialize agent, user, pass=nil, database=nil
      if user.kind_of?(Hash)
        pass = user['password']
        database = user['database']
        user = user['username']
      end
      @ui = agent or fail("no agent")
      @username = user or fail("no user")
      @password = pass or fail("no password")
      @database = database or fail("no database")
    end
    def sql_xml sql
      fail("don't make me deal with escaping quotes: #{sql.inspect}") if sql.index('"')
      %x{mysql -u #{@username} --password=#{@password} -X #{@database} -e "#{sql}"}
    end
    def sql_xml_doc sql
      xml = sql_xml sql
      '' == xml ? nil : REXML::Document.new(xml)
    end
    def dump dirpath
      glob = File.join(dirpath, "dump-#{@database}-*.sql")
      dumps = Dir[glob]
      if dumps.any?
        one = these.size == 1
        @ui.out colorize("notice:",:yellow) << " dump#{'s' unless one} already exist#{'s' if one}: #{these.join(', ')}"
        nil
      else
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
      @ui.out colorize('sql:', :yellow) << sql
      unless @ui.dry_run?
        xml = sql_xml sql
        fail("not expected #{xml.inspect}") if '' != xml
      end
      nil
    end
    def one_or_more_exists? sql
      doc = sql_xml_doc(sql, db) or fail("sql problems")
      found = doc.root.elements[1].elements['//field'].text
      fail("positive integer expected, had #{found.inspect}") unless (/^\d+$/ =~ found)
      amt = found.to_i
      found >= 1
    end
    def one_not_zero_exists? sql
      doc = sql_xml_doc(sql) or fail("sql problems")
      case found = doc.root.elements[1].elements['//field'].text
      when '1'; true
      when '0'; false
      else; fail("expecting zero or one had #{found.inspect} from query: #{sql}")
      end
    end
  end


  # move to tinyscript-support
  class SvnWorkingCopy
    include Colorize
    def initialize path, repo_url=nil, repo_revision=nil
      @create_parent_dir = false
      @abs_path = path
      @repo_url = repo_url
      @repo_revision = repo_revision
    end
    attr_reader :repo_revision, :abs_path, :repo_url
    def create_if_necessary! ui
      ret = nil
      if path_exists?
        puts colorize('exists: ',:magenta) << abs_path
        if ! is_repo?
          ui.out colorize('SUCK', :bright, :red) << " exists but is not repo: #{abs_path}"
          ret = :exists_but_is_not_repo
        end
      else
        empty_dir = File.dirname(abs_path)
        if ! File.directory?(empty_dir)
          if @create_parent_dir
            FileUtils.mkdir_p(empty_di, :verbose => true, :noop => ui.dry_run?)
          else
            ui.out "containing directory must exist"
            return :parent_directory_does_not_exist
          end
        end
        if ! @repo_revision
          ui.out "won't do svn checkout withot a revision number"
          ret = :no_revision_number
        else
          cmd = "svn co #{repo_url}@#{repo_revision} #{abs_path}"
          ui.out colorize("attempting svn checkout:", :bright, :green) << " #{cmd}"
          if ! ui.dry_run?
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
      foo = bar = ''
      Open3.popen3(cmd) do |sin, sout, serr|
        while foo || bar do
          if bar && bar = sout.gets
            @io.out bar
          elsif foo && foo = serr.gets  # don't read from err while out is still open
            @io.out color('svn error:', :red) << " #{foo}"
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
        a = opts[:script_root_path] or fail("need :script_root_absolute_path in opts to build template")
        b = opts[:templates_directory] or fail("need :template_directory in opts to build template")
        abs_path = File.join(a,b,name)
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
          if argv.size == 0 && @opts[:list]
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
        elsif @opts[:list]
          redef(:on_success){ nil }
          tasks = task_context.tasks.sort{|x, y| x.short_name <=> y.short_name}
          if @opts[:dependencies]
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
          run @opts, @reparse_argv
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
        tableize(matrix) do |cel_a, width_a, cel_b, width_b|
          out sprintf("%-#{width_a}s  %-#{width_b}s", cel_a, cel_b)
        end
      end
    end
  end
end
