require File.dirname(__FILE__) + '/helper'

module Hipe::Tinyscript
  class TestEpeen < Test::Unit::TestCase
    include Hipe::Tinyscript::Support
    def test_epeen_basics
      require 'ruby-debug'
      cls = EpeenStruct.new(:bling, :blang, :bazz)
      empty = cls.new
      assert_equal empty.keys.map(&:to_s).sort, %w(bazz blang bling)
      assert empty.bling.nil?
      assert empty.blang.nil?
      assert empty.bazz.nil?
      empty[:bling] = 'foo'
      assert_equal empty.bling, 'foo'
      empty.bling = 'bar'
      assert_equal empty.bling, 'bar'
      empty[:new_key] = 'new value'
      assert empty.respond_to? :new_key
      assert empty.respond_to? :new_key=
      assert_equal empty.new_key, 'new value'
    end

    class SomePeen < EpeenStruct.new; end
    class OtherPeen < EpeenStruct.new(:foo, :bar); end

    def test_epeen_should_throw_with_too_many_args
      e = assert_raises(ArgumentError) do
        SomePeen.new('foo', 'bar')
      end
      assert_match /\Atoo many arguments \(2\).  expecting \(\).\z/, e.message
      e = assert_raises(ArgumentError) do
        OtherPeen.new('a', 'b', 'c')
      end
      assert_match /\Atoo many arguments \(3\).  expecting \(foo, bar\).\z/, e.message
    end
  end
end