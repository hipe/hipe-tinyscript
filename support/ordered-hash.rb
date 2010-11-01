require 'pp'
require 'stringio'

module Hipe
  module Tinyscript
    module Support ; end
  end
end

module Hipe::Tinyscript::Support
  class OrderedHash
    # 1.8.7 compatibility, there are some things i don't like about the stdlib version
    # mainly this is for making ordered json objects
    #
    @json_indent = 2
    class << self
      def json_indent; @json_indent || 2 end
    end
    def initialize
      @order = []
      @hash = {}
    end
    def []= k, v
      @order.include?(k) or @order.push(k)
      @hash[k] = v
    end
    def each
      @order.each do |k|
        yield(k, self[k])
      end
    end
    [ :[], :key?, :size ].each do |meth|
      define_method(meth){ |k| @hash[k] }
    end
    def map
      @order.map{ |k| yield(self[k]) }
    end
    def keys
      @order.dup
    end
    def jsonesque
      io = StringIO.new
      PP.pp self, io
      io.seek(0)
      io.read
    end
    def pretty_print q
      q.group(self.class.json_indent, '{', '}') do
        q.seplist(self, lambda{ q.comma_breakable }, :each) do |k, v|
          q.group do
            q.pp k.to_s
            q.text ':'
            q.group(self.class.json_indent) do
              q.breakable ''
              v.nil? ? q.text('null') : q.pp(v)
            end
          end
        end
        q.breakable
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  oh = Hipe::Tinyscript::Support::OrderedHash
  h = oh.new
  h[:foo] = 'bar'
  h[:biff] = 'baz'
  h[:fizz] = ['abcabcabcabcabcabc abcabcabcabcabcabcabcabcabc 1234231414312341324','b']
  h['fazz'] = (hash = oh.new)
  hash['blah blah'] = 1
  hash[:candy] = 1
  hash[:dandy] = true
  hash[:fandy] = false
  hash[:gandy] = nil
  hash[:handy] = ''
  puts h.jsonesque
end
