module Hipe::Tinyscript::Ui::Commands
  class Spec < Hipe::Tinyscript::Ui::Command
    class SpecCommand < Hipe::Tinyscript::Command
    end
    description "input or output metadata about the application interface as json."
    subcommands SpecCommand
  end
end

Dir[File.dirname(__FILE__)+'/spec/*.rb'].each{ |file| require file }
