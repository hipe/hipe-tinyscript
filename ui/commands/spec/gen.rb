require 'fileutils'
require 'hipe-tinyscript/support/multiplex'
require 'hipe-tinyscript/support/ordered-hash'

class Hipe::Tinyscript::Ui::Commands::Spec # this is not the declaration but a reopening!
  class Gen < SpecCommand
    attr_accessor :app
    description "output metadata about the application interface as json."
    parameter :app, "the executable application file", :positional => true, :required => true

    Oh = Hipe::Tinyscript::Support::OrderedHash
    def execute
      ai = Hipe::Tinyscript::Support::Multiplex::AppInfo.new(
        {:path => param(:app)}, File.dirname(FileUtils.pwd))
      unless ai.valid?
        ai.errors.each{ |e| out colorize('error: ', :red) << e.message }
        return ai.errors.last.name_symbol
      end
      root_hash = Oh.new
      hash = root_hash
      timestamp = Time.now.strftime('%Y-%m-%d %H:%I:%S')
      hash[:comment] = "Generated by #{self.app.program_name} version #{self.app.version} on #{timestamp}"
      hash[:syntax_version] = self.app.version
      app = ai.app_class.new
      hash[:application] = Oh[:program_name, app.program_name]
      hash = hash[:application] # chomp!
      (desc = app.description).any? and hash[:description_lines] = desc
      cmds = app.commands
      cmds.any? and hash[:commands] = []
      cmds.each do |cmd_class|
        hash[:commands].push command_hash(cmd_class)
      end
      root_hash.jsonesque(outs)
    end
  private
    def command_hash cmd_class
      cmd = cmd_class.documenting_instance
      hash = Oh.new
      hash[:short_name] = cmd.short_name
      (desc = cmd.description_lines_enhanced).any? and hash[:description_lines] = desc
      parameters = cmd.send(:parameter_set).parameters.select{ |p| :help != p.sym }
      parameters.any? and hash[:parameters] = (params = [])
      parameters.each do |param|
        params.push parameter_hash param
      end
      hash
    end
    def parameter_hash param
      hash = Oh.new
      hash[:normalized_name] = param.normalized_name
      param.required? and hash[:required] = true
      if param.type && :string != param.type
        hash[:type] = param.type
        if :enum == param.type
          hash[:enum] = []
          param.enum.keys.sort.each{ |k| hash[:enum].push([k, param.enum[k]]) }
        end
      end
      param.many? and hash[:many] = true
      param.has_default? and hash[:default] = param.default # watch for array types
      (lines=param.description_lines_enhanced).any? and hash[:description_lines] = lines
      hash
    end
  end
end
