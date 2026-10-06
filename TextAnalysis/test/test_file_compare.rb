# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/file_compare"

class TestFileCompare < Minitest::Test
  def with_files(a, b)
    Dir.mktmpdir do |dir|
      path_a = File.join(dir, "a.txt")
      path_b = File.join(dir, "b.txt")
      File.write(path_a, a, mode: "w:UTF-8")
      File.write(path_b, b, mode: "w:UTF-8")
      yield path_a, path_b
    end
  end

  def test_identical_files
    with_files("abc\n", "abc\n") do |a, b|
      result = FileIntegrityComparator::Comparator.new(a, b).compare
      assert result.identical
      assert_empty result.differences
    end
  end

  def test_modified_character_and_column
    with_files("nome=joao\n", "nome=joana\n") do |a, b|
      result = FileIntegrityComparator::Comparator.new(a, b).compare
      refute result.identical
      diff = result.differences.first
      assert_equal :modified, diff.type
      assert_equal 9, diff.column
      assert_equal 2, diff.levenshtein
    end
  end

  def test_added_line
    with_files("a\nb\n", "a\nb\nc\n") do |a, b|
      result = FileIntegrityComparator::Comparator.new(a, b).compare
      refute result.identical
      assert result.differences.any? { |d| d.type == :added }
    end
  end

  def test_deleted_line
    with_files("a\nb\nc\n", "a\nc\n") do |a, b|
      result = FileIntegrityComparator::Comparator.new(a, b).compare
      refute result.identical
      assert result.differences.any? { |d| d.type == :deleted }
    end
  end

  def test_levenshtein
    assert_equal 3, FileIntegrityComparator::Levenshtein.distance("kitten", "sitting")
  end
end
