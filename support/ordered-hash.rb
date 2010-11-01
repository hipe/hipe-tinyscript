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
      def [] (*kvs)
        oh = allocate
        oh.send(:init_perl_style, *kvs)
        oh
      end
    end
    def initialize
      @order = []
      @hash = {}
    end
    def init_perl_style *kvs
      0 == (kvs.size % 2) or raise ArgumentError.new("must have even number of keys, not #{kvs.size}")
      @order = (0..kvs.size-2).step(2).map{ |i| kvs[i] }
      @hash = Hash[*kvs]
    end
    private :init_perl_style
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
    def jsonesque outs=nil
      use_outs = outs || StringIO.new
      PP.pp self, use_outs
      if outs.nil?
        use_outs.seek(0)
        use_outs.read
      else
        use_outs
      end
    end
    def pretty_print q
      q.group(self.class.json_indent, '{', '}') do
        q.seplist(self, lambda{ q.comma_breakable }, :each) do |k, v|
          q.group do
            q.pp k.to_s
            q.text ':'
            q.group(self.class.json_indent) do
              q.breakable ''
              case v
              when nil    ; q.text('null')
              when Symbol ; q.pp(v.to_s)
              else        ; q.pp(v)
              end
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
  h = oh[:foo, 'bar', :biff, 'baz']
  h[:fizz] = ['abcabcabcabcabcabc abcabcabcabcabcabcabcabcabc 1234231414312341324','b']
  h['fazz'] = (hash = oh.new)
  hash['blah blah'] = 1
  hash[:barf] = oh[:candy, 1, :dandy, true, :fandy, false, :gandy, nil, :handy, '']
  puts h.jsonesque
end
