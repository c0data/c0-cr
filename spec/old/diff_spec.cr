require "./spec_helper"

describe C0::Diff do
  describe ".parse" do
    it "parses a simple single-file diff" do
      buf = C0::Diff.build do |b|
        b.file("foo.txt") do
          b.replace("Hello ", "world", "universe", "!")
        end
      end

      edits = C0::Diff.parse(buf)
      edits.size.should eq(1)
      String.new(edits[0].path).should eq("foo.txt")
      edits[0].sections.size.should eq(1)

      section = edits[0].sections[0]
      String.new(section.search_pattern).should eq("Hello world!")
      String.new(section.replacement).should eq("Hello universe!")
    end

    it "parses multi-file diffs" do
      buf = C0::Diff.build do |b|
        b.file("foo.txt") do
          b.replace("Hello ", "world", "universe")
        end
        b.file("bar.txt") do
          b.replace("Goodbye ", "earth", "mars")
        end
      end

      edits = C0::Diff.parse(buf)
      edits.size.should eq(2)
      String.new(edits[0].path).should eq("foo.txt")
      String.new(edits[1].path).should eq("bar.txt")
    end

    it "parses multiple sections in one file" do
      buf = C0::Diff.build do |b|
        b.file("app.cr") do
          b.replace("def ", "foo", "bar")
          b.replace("def ", "baz", "qux")
        end
      end

      edits = C0::Diff.parse(buf)
      edits[0].sections.size.should eq(2)
      String.new(edits[0].sections[0].search_pattern).should eq("def foo")
      String.new(edits[0].sections[0].replacement).should eq("def bar")
      String.new(edits[0].sections[1].search_pattern).should eq("def baz")
      String.new(edits[0].sections[1].replacement).should eq("def qux")
    end

    it "parses sections with section builder" do
      buf = C0::Diff.build do |b|
        b.file("test.txt") do
          b.section do |s|
            s.anchor("prefix ")
            s.sub("old_value", "new_value")
            s.anchor(" suffix")
          end
        end
      end

      edits = C0::Diff.parse(buf)
      section = edits[0].sections[0]
      String.new(section.search_pattern).should eq("prefix old_value suffix")
      String.new(section.replacement).should eq("prefix new_value suffix")
    end

    it "parses multiple substitutions in one section" do
      buf = C0::Diff.build do |b|
        b.file("test.txt") do
          b.section do |s|
            s.sub("foo", "bar")
            s.anchor(" and ")
            s.sub("baz", "qux")
          end
        end
      end

      edits = C0::Diff.parse(buf)
      section = edits[0].sections[0]
      String.new(section.search_pattern).should eq("foo and baz")
      String.new(section.replacement).should eq("bar and qux")
    end
  end

  describe ".apply" do
    it "applies a simple substitution" do
      buf = C0::Diff.build do |b|
        b.file("foo.txt") do
          b.replace("Hello ", "world", "universe", "!")
        end
      end

      files = {"foo.txt" => "Hello world!"}
      result = C0::Diff.apply(buf, files)
      result["foo.txt"].should eq("Hello universe!")
    end

    it "applies multi-file edits" do
      buf = C0::Diff.build do |b|
        b.file("a.txt") do
          b.replace("", "foo", "bar")
        end
        b.file("b.txt") do
          b.replace("", "baz", "qux")
        end
      end

      files = {
        "a.txt" => "foo",
        "b.txt" => "baz",
      }
      result = C0::Diff.apply(buf, files)
      result["a.txt"].should eq("bar")
      result["b.txt"].should eq("qux")
    end

    it "preserves unmodified files" do
      buf = C0::Diff.build do |b|
        b.file("a.txt") do
          b.replace("", "old", "new")
        end
      end

      files = {
        "a.txt"     => "old",
        "other.txt" => "untouched",
      }
      result = C0::Diff.apply(buf, files)
      result["other.txt"].should eq("untouched")
    end

    it "applies multiple sections sequentially" do
      buf = C0::Diff.build do |b|
        b.file("code.cr") do
          b.replace("def ", "hello", "greet")
          b.replace("def ", "goodbye", "farewell")
        end
      end

      files = {"code.cr" => "def hello\ndef goodbye\n"}
      result = C0::Diff.apply(buf, files)
      result["code.cr"].should eq("def greet\ndef farewell\n")
    end

    it "raises when file not found" do
      buf = C0::Diff.build do |b|
        b.file("missing.txt") do
          b.replace("", "a", "b")
        end
      end

      expect_raises(C0::Error, "File not found") do
        C0::Diff.apply(buf, {} of String => String)
      end
    end

    it "raises when pattern not found" do
      buf = C0::Diff.build do |b|
        b.file("f.txt") do
          b.replace("", "needle", "replacement")
        end
      end

      expect_raises(C0::Error, "Pattern not found") do
        C0::Diff.apply(buf, {"f.txt" => "no match here"})
      end
    end

    it "raises when pattern is ambiguous (multiple matches)" do
      buf = C0::Diff.build do |b|
        b.file("f.txt") do
          b.replace("", "x", "y")
        end
      end

      expect_raises(C0::Error, "found 2 times") do
        C0::Diff.apply(buf, {"f.txt" => "x and x"})
      end
    end

    it "handles realistic code edit" do
      buf = C0::Diff.build do |b|
        b.file("src/app.cr") do
          b.section do |s|
            s.anchor("class App\n  def ")
            s.sub("run", "start")
            s.anchor("\n    puts ")
            s.sub("\"running\"", "\"starting\"")
          end
        end
      end

      source = "class App\n  def run\n    puts \"running\"\n  end\nend\n"
      files = {"src/app.cr" => source}
      result = C0::Diff.apply(buf, files)
      result["src/app.cr"].should eq("class App\n  def start\n    puts \"starting\"\n  end\nend\n")
    end
  end
end
