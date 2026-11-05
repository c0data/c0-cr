module C0
  # C0-DIFF: atomic multi-file edits with anchored patterns (DIFF.md).
  #
  #   diff = C0::Diff.build do |d|
  #     d.file("greeting.txt") do
  #       d.section { |s| s.anchor("Hello "); s.sub("world", "universe"); s.anchor("!") }
  #     end
  #     d.file("tally.rb") do
  #       d.section { |s| s.anchor("def tally(items)") }
  #       d.replace_all("count", "total")
  #       d.section { |s| s.anchor("end") }
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

    # A section: one anchored pattern, plus the replace-alls that follow it.
    struct Section
      getter units : Array(Unit)
      getter replaces : Array({Bytes, Bytes})

      def initialize(@units : Array(Unit), @replaces = Array({Bytes, Bytes}).new)
      end

      def search : Bytes
        io = IO::Memory.new
        @units.each { |u| io.write(u.old) }
        io.to_slice
      end

      def replacement : Bytes
        io = IO::Memory.new
        @units.each { |u| io.write(u.new || u.old) }
        io.to_slice
      end
    end

    # A file's edits: replace-alls before any section apply to the whole
    # file (up to the first match).
    struct FileEdit
      getter path : String
      getter leading_replaces : Array({Bytes, Bytes})
      getter sections : Array(Section)

      def initialize(@path : String, @leading_replaces : Array({Bytes, Bytes}), @sections : Array(Section))
      end
    end

    # Parse a diff document (with or without its SYN heading).
    def self.parse(buf : Bytes) : Array(FileEdit)
      ptr = buf.to_unsafe
      len = buf.size.to_i32
      pos = Scan.layout(buf, 0, len)
      if pos < len && ptr[pos] == SYN
        heading, pos = Document.parse_heading(buf, pos + 1, len)
        if (shape = heading.shape) && shape != "diff"
          raise Error.new("heading declares shape '#{shape}', not diff")
        end
      end
      files = Array(FileEdit).new
      path = nil
      leading = Array({Bytes, Bytes}).new
      sections = Array(Section).new
      flush = ->{
        if p = path
          files << FileEdit.new(p, leading, sections)
        end
        leading = Array({Bytes, Bytes}).new
        sections = Array(Section).new
      }
      while pos < len
        pos = Scan.layout(buf, pos, len)
        break if pos >= len
        b = ptr[pos]
        dead = false
        if b == BEL
          p2 = Scan.layout(buf, pos + 1, len)
          if p2 < len && (ptr[p2] == FS || ptr[p2] == GS || ptr[p2] == RS)
            dead = true
            pos = p2
            b = ptr[pos]
          else
            pos = Scan.comment(buf, pos, len) # a note
            next
          end
        end
        case b
        when FS
          name, pos = read_name(buf, pos + 1, len)
          unless dead
            flush.call
            raise Error.new("the same path twice: #{name}") if files.any? { |f| f.path == name }
            path = name
          end
        when GS
          raise Error.new("section before any file") unless path
          units, pos = parse_pattern(buf, pos + 1, len)
          sections << Section.new(units) unless dead
        when RS
          raise Error.new("replace-all before any file") unless path
          old, pos = read_dvalue(buf, pos + 1, len)
          raise Error.new("replace-all with an empty old part") if old.empty?
          raise Error.new("replace-all without SUB") unless pos < len && ptr[pos] == SUB
          new, pos = read_dvalue(buf, pos + 1, len)
          unless dead
            if sections.empty?
              leading << {old, new}
            else
              sections[-1].replaces << {old, new}
            end
          end
        when ETB
          pos = Scan.plain(buf, Scan.layout(buf, pos + 1, len), len)
        when EOT
          pos = Scan.layout(buf, pos + 1, len)
          raise SyntaxError.new("unexpected byte after EOT", pos) if pos < len && ptr[pos] != SYN && ptr[pos] != EM
          break
        else
          raise SyntaxError.new("unexpected byte in a diff body", pos)
        end
      end
      flush.call
      files
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

    # Apply one file's edits (DIFF.md "Sections", "Replace-all").
    def self.apply_file(data : Bytes, edit : FileEdit) : Bytes
      cursor = 0
      matches = Array({Int32, Int32, Bytes}).new
      edit.sections.each do |sec|
        search = sec.search
        raise Error.new("empty search text in #{edit.path}") if search.empty?
        first = find(data, search, cursor)
        raise Error.new("pattern not found in #{edit.path}: #{String.new(search).inspect}") if first < 0
        raise Error.new("pattern matched more than once in #{edit.path}: #{String.new(search).inspect}") if find(data, search, first + 1) >= 0
        matches << {first, first + search.size, sec.replacement}
        cursor = first + search.size
      end
      # scopes: before the first match, and after each match to the next
      io = IO::Memory.new
      first_start = matches.empty? ? data.size : matches[0][0]
      io.write(replace_all(data[0...first_start], edit.leading_replaces, edit.path))
      matches.each_with_index do |(s, e, repl), i|
        io.write(repl)
        nxt = i + 1 < matches.size ? matches[i + 1][0] : data.size
        io.write(replace_all(data[e...nxt], edit.sections[i].replaces, edit.path))
      end
      io.to_slice
    end

    private def self.replace_all(segment : Bytes, replaces : Array({Bytes, Bytes}), path : String) : Bytes
      replaces.each do |(old, new)|
        count = 0
        io = IO::Memory.new
        pos = 0
        while (i = find(segment, old, pos)) >= 0
          io.write(segment[pos...i])
          io.write(new)
          pos = i + old.size
          count += 1
        end
        raise Error.new("replace-all found nothing in #{path}: #{String.new(old).inspect}") if count == 0
        io.write(segment[pos...segment.size])
        segment = io.to_slice
      end
      segment
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

    private def self.read_name(buf : Bytes, pos : Int32, len : Int32) : {String, Int32}
      pos = Scan.layout(buf, pos, len)
      raise SyntaxError.new("a path cannot be text", pos) if pos < len && buf[pos] == STX
      stop = Scan.plain(buf, pos, len)
      {String.new(C0.trim(buf[pos...stop])), stop}
    end

    private def self.read_dvalue(buf : Bytes, pos : Int32, len : Int32) : {Bytes, Int32}
      ptr = buf.to_unsafe
      pos = Scan.layout(buf, pos, len)
      return {Bytes.empty, pos} if pos >= len
      if ptr[pos] == STX
        stop = Scan.text(buf, pos, len)
        val = C0.decode_text(buf[(pos + 1)...(stop - 1)])
        {val, Scan.layout(buf, stop, len)}
      elsif ptr[pos] >= 0x20_u8
        stop = Scan.plain(buf, pos, len)
        {C0.trim(buf[pos...stop]), stop}
      else
        {Bytes.empty, pos}
      end
    end

    private def self.parse_pattern(buf : Bytes, pos : Int32, len : Int32) : {Array(Unit), Int32}
      ptr = buf.to_unsafe
      units = Array(Unit).new
      loop do
        old, pos = read_dvalue(buf, pos, len)
        if pos < len && ptr[pos] == SUB
          new, pos = read_dvalue(buf, pos + 1, len)
          units << Unit.new(old, new)
        else
          units << Unit.new(old, nil)
        end
        # notes after a unit
        while pos < len && ptr[pos] == BEL
          p2 = Scan.layout(buf, pos + 1, len)
          break unless p2 < len && (ptr[p2] >= 0x20_u8 || ptr[p2] == STX)
          pos = Scan.layout(buf, Scan.comment(buf, pos, len), len)
        end
        break unless pos < len && ptr[pos] == US
        pos += 1
      end
      {units, pos}
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

    def section(& : SectionBuilder ->) : Nil
      @io.write_byte(GS)
      yield SectionBuilder.new(@io)
    end

    # anchor, old → new, anchor in one call.
    def replace(context_before : String, old_text : String, new_text : String, context_after : String = "") : Nil
      section do |s|
        s.anchor(context_before) unless context_before.empty?
        s.sub(old_text, new_text)
        s.anchor(context_after) unless context_after.empty?
      end
    end

    # RS old SUB new: every occurrence within the current section's scope.
    def replace_all(old_text : String, new_text : String) : Nil
      raise Diff::Error.new("replace-all needs a non-empty old part") if old_text.empty?
      @io.write_byte(RS)
      C0.write_value(@io, old_text)
      @io.write_byte(SUB)
      C0.write_value(@io, new_text)
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

  class SectionBuilder
    @first : Bool

    def initialize(@io : IO::Memory)
      @first = true
    end

    def anchor(text : String) : Nil
      sep
      C0.write_value(@io, text)
    end

    def sub(old_text : String, new_text : String) : Nil
      sep
      C0.write_value(@io, old_text)
      @io.write_byte(SUB)
      C0.write_value(@io, new_text)
    end

    private def sep : Nil
      @io.write_byte(US) unless @first
      @first = false
    end
  end
end
