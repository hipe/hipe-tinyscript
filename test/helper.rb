require 'rubygems' # why is this necessary here even if it's in Rakefile!? it is
require 'test/unit'

base = File.expand_path('../..', __FILE__)
require base + '/core'
require base + '/support'

# module Hipe::Tinyscript
  # class MyTest < Test::Unit::TestCase; end
  # can't do above ! etc
# end