module Hipe
  module Tinyscript
    
    module Colorize
      Codes = {:bright=>'1', :red=>'31', :green=>'32', :yellow=>'33',
        :blue=>'34',:magenta=>'35',:bold=>'1',:blink=>'5'}
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
