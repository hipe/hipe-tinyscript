#
# A multiplexing app is a 'super app' that is just a wrapper around many smaller,
# existing apps. (The architecture of git resembles this.  It started as a
# collection of independant perl scripts.)
#
# In this manner you can get small apps (scripts) to work alone and then add them
# to a bigger app by simply telling the wrapper app the path to the actual app.
#
# An :apps element in the @params hash (typicially in a conf file) is used
# to determine the paths to the different apps.  Apps will be 'loaded' lazily as
# needed.  It will barf unless the child apps are smart about how they run:
# the file used to define the app class must not actually run it when it is loaded
# (either do these two things in separate files or check for $PROGRAM_NAME)
#
# class MyThing::App < Hipe::Tinyscript::Support::Multiplex::App
#   config {
#     :apps => [
#       { :path => 'fooscript' },                     # relative to the file that defines yr superapp
#       { :path => 'barscript.d/barscript' },         # also relative to the file
#       { :path => "#{ENV['HOME']}/bin/baz-script" }, # abs path
#     ]
#   }
#   # ...
# end
#
# MyThing::App.new.run(ARGV)
#


module Hipe::Tinyscript::Support::Multiplex
  EpeenStruct = Hipe::Tinyscript::Support::EpeenStruct

  class AppInfos < Array
    def initialize app, infos, parent_app_file
      super(infos.size)
      @app = app
      dn = File.dirname(parent_app_file)
      infos.each_with_index do |info, idx|
        self[idx] = AppInfo.new(@app, info, dn)
      end
    end
  end

  class AppInfo < EpeenStruct.new()
    def initialize host_app_class, info, host_app_dirname
      super()
      [:cd, :git].each do |k|
        self[k] = info[k] if info.key?(k)
      end
      @path_provided = info[:path]
      @host_app_class = host_app_class
      @host_app_dirname = host_app_dirname
    end
    def path_basename
      File.basename path_interpolated
    end
    def path_dirname
      return nil unless key? :cd
      return "#{path_interpolated}.d" if :dir == self[:cd]
      File.expand_path(cd, path_interpolated)
    end
    def path_interpolated
      @path_interpolated ||= self.class.expand_app_path(path_provided, @host_app_basname)
    end
    attr_reader :path_provided
    def app_class
      @app_class ||= load_class
    end
    attr_reader :errors
    def valid?
      # triggers things that would call add_error
      app_class
      @errors.nil?
    end
    class << self
      def expand_app_path path, host_app_dirname
        path[0] == '/' and return path
        if path.index('<%=')
          @app_path_name_templ_vars ||= Hipe::Tinyscript::Support::ClosedStruct.new(:home => proc{ ENV['HOME'] })
          Hipe::Tinyscript::Support::Template.new(path).interpolate(@app_path_name_templ_vars)
        else
          File.expand_path(path, host_app_dirname)
        end
      end
    end
  private
    def add_error name_symbol, message=nil, opts={}
      hash = EpeenStruct[ opts.dup ]
      message.nil? or hash[:message] = message
      hash[:name_symbol] = name_symbol
      @errors ||= []
      @errors.push(hash)
      return nil # important
    end
    def load_class
      path = path_interpolated
      File.exist?(path) or return add_error(:app_file_not_found, "not found: #{path}")
      sz1 = Hipe::Tinyscript::App.subclasses.size
      load path # can't require, it requires a '*.rb'
      sz2 = Hipe::Tinyscript::App.subclasses.size
      case sz2 - sz1
      when 1 ; # ok, fall thru
      when 0 ; return add_error(:app_sublass_not_found,
        "File does not define any immediate subclasses of ::App? #{path}")
      else ; return add_error(:multiple_subclasses_found,
        "File defines more than one (#{sz2-sz1}) subclasses of ::App: #{path}")
      end
      cls = Hipe::Tinyscript::App.subclasses.last
      cls.program_name = File.basename(path) # es muss sein
      cls
    end
  end

  class MultiplexCommand < Hipe::Tinyscript::App::DefaultCommand # oh boy
    FOUR = 4 # temporary blah blah
    FIXME = Hipe::Tinyscript::Command::FIXME
    attr_writer :app
    def show_maybe_command_help cmd=nil
      cmd.nil? or throw :app_interrupt, [:show_command_specific_help, cmd] # just yes
      matrix = []
      @app.commands.each do |c|
        matrix.push [c.short_name, c.desc_oneline]
      end
      @app.valid_app_infos.map(&:app_class).sort{ |a, b| a.program_name <=> b.program_name }.each do |app_cls|
        app_cls.new.commands.each do |c| # ich muss sein
          matrix.push ["#{app_cls.program_name} #{c.short_name}", c.desc_oneline]
        end
      end
      t = tableize(matrix)
      new_col1_width = [ t.width(0) + FOUR, option_parser.summary_width ].max
      option_parser.summary_width = new_col1_width
      out option_parser.help
      out colorize('commands:', :bright, :green)
      if t.rows.any?
        whitespace = ' ' * (FOUR + FIXME)
        fmt = "    %-#{t.width(0)}s#{whitespace}%-#{t.width(1)}s"
        t.rows.each{ |colA, colB| out sprintf(fmt, colA, colB) }
      end
      :interrupt_handled
    end
  end

  class AppCommandAdapter
    # makes an app look like a command for the purpose of running it
    # from the multiplexing app
    #
    attr_accessor :app # the parent app, not the target app
    def new; self end  # objects of this class should quack like class objects
    def initialize cls
      @class = cls
    end
    def run parameters, argv
      app = @class.new
      # parameters ignored!? because the target app should run just
      # as it does when it is not inside a multiplexer
      app.run argv.slice(1..-1)
    end
  end

  class App < Hipe::Tinyscript::App
    attr_reader :app
    default_command_class MultiplexCommand
    class << self
      # give reflection of the paths for apps that are in their own repo (used externally)
      def app_infos
        @app_infos ||= begin
          (@basefile && @config && @config.key?(:apps)) ? AppInfos.new(self, @config[:apps], @basefile) : nil
        end
      end
      attr_accessor :basefile
      def inherited cls
        cls.basefile = parse_call_stack_line(caller.first)[:path]
      end
    end
    # called from elsewhere
    def app_infos
      self.class.app_infos
    end
    def valid_app_infos
      self.class.app_infos.map do |ai|
        ai.valid? ? ai : begin
          ai.errors.each do |err|
            out colorize('notice: ', :yellow) << err.message
          end
          nil
        end
      end.compact
    end
  private
    # you're guaranteed that argv has a first arg is a non-switch arg
    def find_commands argv
      (cmds = super(argv)).any? and return cmds # doing this makes life suck less
      apps = valid_app_infos
      found = fuzzy_match(apps, argv.first, :path_basename)
      found.size == 1 or return found
      [AppCommandAdapter.new(found.first.app_class)]
    end
  end
end
