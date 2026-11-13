module C0
  # C0DIFF: atomic multi-file edits with anchored patterns (DIFF.md). A
  # diff is an ordinary document of `shape` `diff`: files of records, each
  # record a pattern of units, with `old␚␟new` (supersession at the unit
  # grain) as the substitution.
  #
  #   diff = C0::Diff.build do |d|
  #     d.file("greeting.txt") do
  #       d.record { |r| r.anchor("Hello "); r.sub("world", "universe"); r.anchor("!") }
  #     end
  #   end
  #   C0::Diff.apply(diff, {"greeting.txt" => "Hello world!"})
  module Diff
    class Error < C0::Error; end

    # One unit of a pattern: an anchor (new is nil) or a substitution.
    struct Unit
      getter old : Bytes
      getter new : Bytes?

      def initialize(@old : Bytes, @new : Bytes?)
      end

      def anchor? : Bool
        @new.nil?
      end
    end

    # One record: an anchored pattern.
    struct Pattern
      getter units : Array(Unit)

      def initialize(@units : Array(Unit))
      end

      # What the file must hold, once: anchors and superseded units.
      def search : Bytes
        io = IO::Memory.new
        @units.each { |u| io.write(u.old) }
        io.to_slice
      end

      # What it will hold: superseding units in place of superseded ones.
      def replacement : Bytes
        io = IO::Memory.new
        @units.each { |u| io.write(u.new || u.old) }
        io.to_slice
      end

      def assertion? : Bool
        @units.all?(&.anchor?)
      end
    end

    # A file's records, in order.
    struct FileEdit
      getter path : String
      getter records : Array(Pattern)

      def initialize(@path : String, @records : Array(Pattern))
      end
    end

    # Parse a diff document (with or without its SYN heading), refusing
    # everything DIFF.md lists under "What a diff may not hold".
    def self.parse(buf : Bytes) : Array(FileEdit)
      parser = Parser.new(buf)
      container = Container.new(buf, parser: parser)
      raise Error.new("a diff is one document") unless container.documents.size == 1
      doc = container.first
      if (shape = doc.heading.shape) && shape != "diff"
        raise Error.new("heading declares shape '#{shape}', not diff")
      end
      raise Error.new("a dead element in a diff: a hunk is kept without applying by writing it in a note") if parser.dead_elements > 0
      parser.supersessions.each do |c|
        raise Error.new("supersession at a grain other than the unit") unless c == US
      end
      files = Array(FileEdit).new
      doc.body.files.each do |f|
        if f.leading?
          next if f.groups.empty?
          raise Error.new("a record before the first FS")
        end
        path = String.new(f.name)
        raise Error.new("empty path") if path.empty?
        raise Error.new("the same path twice: #{path}") if files.any? { |e| e.path == path }
        records = Array(Pattern).new
        f.groups.each do |g|
          raise Error.new("GS in a diff") if g.depth > 0
          raise Error.new("a header row in a diff") if g.has_header?
          g.records.each { |r| records << pattern_of(r) }
        end
        files << FileEdit.new(path, records)
      end
      files
    end

    private def self.pattern_of(rec : Record) : Pattern
      raise Error.new("a keyed unit in a diff record") if rec.keyed?
      units = Array(Unit).new
      pending = nil.as(Bytes?)
      rec.units.each do |u|
        raw = u.raw
        raise Error.new("a nested level in a diff record") if C0.level?(raw)
        raise Error.new("a reference in a diff record") if C0.reference?(raw)
        v = C0.value(raw)
        if u.superseded?
          raise Error.new("a chained supersession: its search text would hold what the file never held") if pending
          pending = v
        elsif old = pending
          raise Error.new("a substitution of nothing by nothing") if old.empty? && v.empty?
          units << Unit.new(old, v)
          pending = nil
        else
          units << Unit.new(v, nil)
        end
      end
      Pattern.new(units)
    end

    # Apply a diff to in-memory files. Validates everything first; raises
    # without touching the hash on any error. Returns the edited files.
    def self.apply(diff_buf : Bytes, files : Hash(String, String)) : Hash(String, String)
      edits = parse(diff_buf)
      results = {} of String => Bytes
      edits.each do |e|
        content = files[e.path]? || raise Error.new("no such file: #{e.path}")
        results[e.path] = apply_file(content.to_slice, e)
      end
      out = files.dup
      results.each { |k, v| out[k] = String.new(v) }
      out
    end

    def self.apply(diff_buf : Bytes, files : Hash(String, Bytes)) : Hash(String, Bytes)
      edits = parse(diff_buf)
      results = {} of String => Bytes
      edits.each do |e|
        content = files[e.path]? || raise Error.new("no such file: #{e.path}")
        results[e.path] = apply_file(content, e)
      end
      out = files.dup
      results.each { |k, v| out[k] = v }
      out
    end

    # Apply a diff to files on disk under base_dir, atomically: every file
    # is validated before any is written, and each is written via a
    # temporary file and rename.
    def self.apply_files(diff_buf : Bytes, base_dir : String = ".") : Nil
      edits = parse(diff_buf)
      base = Path.new(base_dir).expand
      planned = Array({Path, Bytes}).new
      edits.each do |e|
        target = (base / e.path).expand
        raise Error.new("path escapes the target directory: #{e.path}") unless target.to_s.starts_with?(base.to_s)
        raise Error.new("no such file: #{e.path}") unless File.exists?(target)
        planned << {target, apply_file(File.read(target).to_slice, e)}
      end
      planned.each do |(target, bytes)|
        tmp = target.to_s + ".c0diff.tmp"
        File.write(tmp, bytes)
        File.rename(tmp, target.to_s)
      end
    end

    # Apply one file's records (DIFF.md "Records"): each search text must
    # match once from the cursor to the end of the file.
    def self.apply_file(data : Bytes, edit : FileEdit) : Bytes
      cursor = 0
      matches = Array({Int32, Int32, Bytes}).new
      edit.records.each do |pat|
        search = pat.search
        raise Error.new("empty search text in #{edit.path}") if search.empty?
        first = find(data, search, cursor)
        raise Error.new("pattern not found in #{edit.path}: #{String.new(search).inspect}") if first < 0
        raise Error.new("pattern matched more than once in #{edit.path}: #{String.new(search).inspect}") if find(data, search, first + 1) >= 0
        matches << {first, first + search.size, pat.replacement}
        cursor = first + search.size
      end
      io = IO::Memory.new
      pos = 0
      matches.each do |(s, e, repl)|
        io.write(data[pos...s])
        io.write(repl)
        pos = e
      end
      io.write(data[pos...data.size])
      io.to_slice
    end

    private def self.find(hay : Bytes, needle : Bytes, from : Int32) : Int32
      return -1 if needle.empty?
      last = hay.size - needle.size
      i = from
      while i <= last
        if hay[i] == needle[0] && hay[i, needle.size] == needle
          return i
        end
        i += 1
      end
      -1
    end

    def self.build(& : DiffBuilder ->) : Bytes
      b = DiffBuilder.new
      yield b
      b.to_slice
    end
  end

  class DiffBuilder
    @io : IO::Memory

    def initialize(heading : Bool = true)
      @io = IO::Memory.new
      if heading
        @io.write_byte(SYN)
        @io.write_byte(SOH)
        @io.write("shape".to_slice)
        @io.write_byte(US)
        @io.write("diff".to_slice)
      end
    end

    def file(path : String, & : ->) : Nil
      @io.write_byte(FS)
      C0.write_name(@io, path.to_slice)
      yield
    end

    # One anchored pattern.
    def record(& : PatternBuilder ->) : Nil
      @io.write_byte(RS)
      yield PatternBuilder.new(@io)
    end

    # anchor, old → new, anchor in one call.
    def replace(context_before : String, old_text : String, new_text : String, context_after : String = "") : Nil
      record do |r|
        r.anchor(context_before) unless context_before.empty?
        r.sub(old_text, new_text)
        r.anchor(context_after) unless context_after.empty?
      end
    end

    # Insert `text` after `anchor`.
    def insert_after(anchor : String, text : String) : Nil
      record do |r|
        r.anchor(anchor)
        r.sub("", text)
      end
    end

    # Remove `old_text`, found once after the cursor.
    def delete(old_text : String, context_before : String = "", context_after : String = "") : Nil
      replace(context_before, old_text, "", context_after)
    end

    # Assert that `text` is present once; nothing changes.
    def assert(text : String) : Nil
      record { |r| r.anchor(text) }
    end

    def note(text : String) : Nil
      @io.write_byte(BEL)
      C0.write_value(@io, text)
    end

    def eot : Nil
      @io.write_byte(EOT)
    end

    def to_slice : Bytes
      @io.to_slice
    end
  end

  class PatternBuilder
    @first : Bool

    def initialize(@io : IO::Memory)
      @first = true
    end

    def anchor(text : String) : Nil
      sep
      C0.write_value(@io, text)
    end

    # `old␚␟new`.
    def sub(old_text : String, new_text : String) : Nil
      sep
      C0.write_value(@io, old_text)
      @io.write_byte(SUB)
      @io.write_byte(US)
      C0.write_value(@io, new_text)
    end

    private def sep : Nil
      @io.write_byte(US) unless @first
      @first = false
    end
  end
end
