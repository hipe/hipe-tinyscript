require 'rubygems'; require 'ruby-debug'; puts "\e[1;5;33mruby-debug\e[0m"
require 'hipe-tinyscript/core'
require 'hipe-tinyscript/support'

module Hipe::Tinyscript::Ui
  class Command < Hipe::Tinyscript::Command
  end
  class App < Hipe::Tinyscript::App
    Version = '0.0.0'
    description "inspects ui of apps and generates things"
    config {}
    commands Command
  end
end

Dir[File.dirname(__FILE__) + '/commands/*.rb'].each{ |file| require file }
