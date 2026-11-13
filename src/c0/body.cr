module C0
  # Zero-copy navigator for a document body: the bytes between a heading
  # and EOT, or the inside of a nested level. The structure (files, groups,
  # header rows, records) is built once by the Parser with dead and
  # superseded elements dropped; everything it returns is a slice into
  # the original buffer.
  #
  # Records before the first GS of a file form an unnamed group; records
  # and groups before the first FS form an unnamed file.
  struct Body
    getter buf : Bytes
    getter start : Int32
    getter stop : Int32
    getter files : Array(FileView)

    # Parse the body in buf[start...stop]. `level` reads it as the inside
    # of a nested level (no commits).
    def initialize(@buf : Bytes, @start : Int32 = 0, @stop : Int32 = buf.size.to_i32, level : Bool = false)
      parser = Parser.new(@buf)
      @files, pos = parser.body(@start, @stop, level: level)
      pos = Scan.layout(@buf, pos, @stop)
      raise SyntaxError.new("unexpected byte in body", pos) if pos < @stop
    end

    # A body already parsed (used by the Parser).
    def initialize(@buf : Bytes, @start : Int32, @stop : Int32, @files : Array(FileView))
    end

    # All groups of all files, in order.
    def groups : Array(Group)
      @files.flat_map(&.groups)
    end

    # Groups of the first file.
    def group_count : Int32
      first_file.groups.size
    end

    def group(i : Int32) : Group
      first_file.groups[i]
    end

    def group(name : String) : Group
      first_file.group(name)
    end

    def [](name : String) : Group
      group(name)
    end

    def [](i : Int32) : Group
      group(i)
    end

    def each_group(& : Group ->) : Nil
      first_file.groups.each { |g| yield g }
    end

    def group_names : Array(Bytes)
      first_file.groups.map(&.name)
    end

    # Name of the first file (empty when the body has no FS).
    def name : Bytes
      first_file.name
    end

    # Records of the body when it is a bare record stream (no FS, no GS):
    # the unnamed group's records.
    def records : Array(Record)
      first_file.groups.first?.try(&.records) || Array(Record).new
    end

    def record_count : Int32
      records.size
    end

    def record(i : Int32) : Record
      records[i]
    end

    def each_record(& : Record ->) : Nil
      records.each { |r| yield r }
    end

    # Whether the body is just records: one unnamed file, one unnamed group.
    def bare? : Bool
      @files.size == 1 && @files[0].leading? && @files[0].groups.size <= 1 &&
        (@files[0].groups.empty? || @files[0].groups[0].depth == 0)
    end

    private def first_file : FileView
      @files[0]
    end

    def raw : Bytes
      @buf[@start...@stop]
    end
  end

  # A file within a body: its name and groups. The leading file is the
  # unnamed one before the first FS.
  struct FileView
    @buf : Bytes
    @name_start : Int32
    @name_end : Int32
    getter groups : Array(Group)
    getter? leading : Bool

    def initialize(@buf : Bytes, @name_start : Int32, @name_end : Int32, @groups : Array(Group), @leading : Bool = false)
    end

    def name : Bytes
      C0.trim(@buf[@name_start...@name_end])
    end

    def group(name : String) : Group
      @groups.each do |g|
        return g if g.name == name.to_slice
      end
      raise C0::KeyError.new("No group named '#{name}'")
    end

    def [](name : String) : Group
      group(name)
    end
  end

  # A group: its depth (GS count; 0 for the unnamed leading group), name,
  # optional header row and records.
  class Group
    @buf : Bytes
    getter depth : Int32
    @name_start : Int32
    @name_end : Int32
    property header : Record?
    getter records : Array(Record)

    def initialize(@buf : Bytes, @depth : Int32, @name_start : Int32, @name_end : Int32, @header : Record?, @records : Array(Record))
    end

    def name : Bytes
      C0.trim(@buf[@name_start...@name_end])
    end

    def has_header? : Bool
      !@header.nil?
    end

    # Header names, or an empty array.
    def headers : Array(Bytes)
      if h = @header
        h.values
      else
        Array(Bytes).new
      end
    end

    def header_count : Int32
      @header.try(&.field_count) || 0
    end

    def header(i : Int32) : Bytes
      headers[i]
    end

    def record_count : Int32
      @records.size
    end

    def record(i : Int32) : Record
      @records[i]
    end

    def each_record(& : Record ->) : Nil
      @records.each { |r| yield r }
    end

    # Index of a header name, or nil.
    def column(name : String) : Int32?
      headers.index { |h| h == name.to_slice }
    end

    # Compatibility: the group as a Table is itself.
    def table : Group
      self
    end
  end

  alias Table = Group

  # One unit of a positional record as written: its raw bytes and whether
  # the unit after it supersedes it (`old␚␟new`).
  struct Unit
    getter raw : Bytes
    getter? superseded : Bool

    def initialize(@raw : Bytes, @superseded : Bool)
    end

    # Logical value.
    def value : Bytes
      C0.value(@raw)
    end
  end

  # A record: positional or keyed. Zero-copy accessors. The positional and
  # keyed accessors report the record's **result**: a superseded unit is
  # not among them; `units` lists every unit as written.
  struct Record
    @buf : Bytes
    @start : Int32
    @end : Int32

    def initialize(@buf : Bytes, @start : Int32, @end : Int32)
    end

    # Raw bytes of the record (after its RS).
    @[AlwaysInline]
    def raw : Bytes
      @buf[@start...@end]
    end

    # Offset of the record's first byte in the buffer.
    def offset : Int32
      @start
    end

    # Whether the record is keyed (its first unit is an SOH).
    def keyed? : Bool
      ptr = @buf.to_unsafe
      p = Scan.layout(@buf, @start, @end)
      while p < @end && (ptr[p] == BEL || ptr[p] == SUB)
        p2 = Scan.layout(@buf, p + 1, @end)
        return true if p2 < @end && ptr[p2] == SOH
        break if p2 >= @end || ptr[p] == SUB || (ptr[p2] < 0x20_u8 && ptr[p2] != STX)
        p = Scan.layout(@buf, Scan.comment(@buf, p, @end), @end)
      end
      p < @end && ptr[p] == SOH
    end

    # ---- positional -----------------------------------------------------

    # Raw slice of unit n of the result (layout at its edges included).
    def field(n : Int32) : Bytes
      each_unit_range do |i, s, e|
        return @buf[s...e] if i == n
      end
      Bytes.empty
    end

    def field_count : Int32
      count = 0
      each_unit_range { |i, s, e| count = i + 1 }
      count
    end

    def fields : Array(Bytes)
      out = Array(Bytes).new
      each_unit_range { |i, s, e| out << @buf[s...e] }
      out
    end

    # Every unit as written, superseded ones included.
    def units : Array(Unit)
      out = Array(Unit).new
      each_written_unit { |s, e, sup| out << Unit.new(@buf[s...e], sup) }
      out
    end

    # Logical value of unit n.
    def value(n : Int32) : Bytes
      C0.value(field(n))
    end

    def values : Array(Bytes)
      fields.map { |f| C0.value(f) }
    end

    # Unit n as a nested level.
    def level(n : Int32) : Body
      Record.level_of(field(n))
    end

    # Unit n as a flat list: a level holding exactly one positional record.
    def list(n : Int32) : Array(Bytes)
      body = level(n)
      recs = body.records
      return Array(Bytes).new if recs.empty? && body.bare?
      raise Error.new("level is not a list (#{recs.size} records)") unless recs.size == 1 && body.bare?
      raise Error.new("level is not a list (header row)") if body.groups[0]?.try(&.has_header?)
      raise Error.new("level is not a list (keyed record)") if recs[0].keyed?
      recs[0].values
    end

    # Unit n as a reference.
    def ref(n : Int32) : Reference
      Reference.parse(field(n))
    end

    # ---- keyed ---------------------------------------------------------

    # Keys in written order.
    def keys : Array(Bytes)
      out = Array(Bytes).new
      each_keyed_range { |k, ks, ke, vs, ve| out << k }
      out
    end

    # Pairs in written order (key, logical value).
    def pairs : Array({Bytes, Bytes})
      out = Array({Bytes, Bytes}).new
      each_keyed_range { |k, ks, ke, vs, ve| out << {k, C0.value(@buf[vs...ve])} }
      out
    end

    # Raw unit for a key (last wins), or nil.
    def field(key : String) : Bytes?
      found = nil
      each_keyed_range do |k, ks, ke, vs, ve|
        found = @buf[vs...ve] if k == key.to_slice
      end
      found
    end

    # Logical value for a key (last wins), or nil.
    def [](key : String) : Bytes?
      field(key).try { |f| C0.value(f) }
    end

    def level(key : String) : Body?
      field(key).try { |f| Record.level_of(f) }
    end

    def has_key?(key : String) : Bool
      !field(key).nil?
    end

    # ---- shared ---------------------------------------------------------

    protected def self.level_of(raw : Bytes) : Body
      t = C0.trim(raw)
      raise Error.new("unit is not a nested level") unless t.size > 0 && t[0] == DLE
      stop = Scan.level(t, 0)
      Body.new(t, 1, stop - 1, level: true)
    end

    # Yields (start, end, superseded) for each positional unit as written.
    private def each_written_unit(& : Int32, Int32, Bool ->) : Nil
      return if keyed?
      ptr = @buf.to_unsafe
      pos = Scan.layout(@buf, @start, @end)
      unit_start = @start
      loop do
        pos = Scan.unit(@buf, pos, @end)
        superseded = false
        nxt = pos
        if pos < @end && ptr[pos] == SUB
          p2 = Scan.layout(@buf, pos + 1, @end)
          if p2 < @end && ptr[p2] == US
            superseded = true
            nxt = p2
          end
        end
        yield unit_start, pos, superseded
        break unless nxt < @end && ptr[nxt] == US
        pos = nxt + 1
        unit_start = pos
      end
    end

    # Yields (index, start, end) for each positional unit of the result.
    private def each_unit_range(& : Int32, Int32, Int32 ->) : Nil
      idx = 0
      each_written_unit do |s, e, sup|
        next if sup
        yield idx, s, e
        idx += 1
      end
    end

    # Yields (key, key_start, key_end, value_start, value_end) per keyed
    # unit of the result.
    private def each_keyed_range(& : Bytes, Int32, Int32, Int32, Int32 ->) : Nil
      ptr = @buf.to_unsafe
      pos = Scan.layout(@buf, @start, @end)
      while pos < @end
        b = ptr[pos]
        if b == SOH
          ks = Scan.layout(@buf, pos + 1, @end)
          ke = Scan.plain(@buf, ks, @end)
          raise SyntaxError.new("key without a value (no US)", ke) unless ke < @end && ptr[ke] == US
          vs = ke + 1
          ve = Scan.unit(@buf, vs, @end)
          superseded = false
          pos = ve
          if ve < @end && ptr[ve] == SUB
            p2 = Scan.layout(@buf, ve + 1, @end)
            if p2 < @end && ptr[p2] == SOH
              superseded = true
              pos = p2
            end
          end
          yield C0.trim(@buf[ks...ke]), ks, ke, vs, ve unless superseded
        elsif b == BEL
          pos = Scan.comment(@buf, pos, @end)
        elsif b == SUB || C0.layout?(b)
          pos += 1
        else
          return
        end
      end
    end
  end

  # A reference (DESIGN.md, References): a group name written plain, or a
  # pattern, a level that is one branch of the target with its values left
  # out. The pattern is reported as the level it is written as.
  struct Reference
    # The group name of a plain reference, or nil for a pattern.
    getter name : Bytes?
    # The pattern of `ENQ DLE … CAN`, or nil for a plain reference.
    getter pattern : Body?

    def initialize(@name : Bytes?, @pattern : Body?)
    end

    # Parse a raw unit holding a reference (notes after it allowed).
    def self.parse(raw : Bytes) : Reference
      t = C0.trim(raw)
      raise Error.new("unit is not a reference") unless t.size > 0 && t[0] == ENQ
      ref, pos = Parser.new(t).reference(0, t.size)
      pos = Scan.layout(t, pos, t.size)
      while pos < t.size
        raise SyntaxError.new("unexpected byte after a reference", pos) unless t[pos] == BEL
        pos = Scan.layout(t, Scan.comment(t, pos), t.size)
      end
      ref
    end

    # Whether the reference names a group as a whole: a plain name, or a
    # pattern that is a bare group line.
    def group? : Bool
      return true if @name
      p = @pattern.not_nil!
      p.files[0].leading? && p.groups.size == 1 && p.groups[0].records.empty?
    end

    # The group named, when the reference names a group as a whole.
    def group_name : Bytes?
      return @name if @name
      group? ? @pattern.not_nil!.groups[0].name : nil
    end

    # The steps of the pattern in walking order (file, groups, record id,
    # field name, then the inner pattern's steps), or the group name alone.
    # Informal: a keyed step contributes its key.
    def path : Array(Bytes)
      if n = @name
        return [n]
      end
      out = Array(Bytes).new
      p = @pattern.not_nil!
      f = p.files[0]
      out << f.name unless f.leading?
      f.groups.each { |g| out << g.name unless g.depth == 0 }
      if rec = f.groups.last.records[0]?
        if rec.keyed?
          out << rec.keys[0]
        else
          rec.fields.each_with_index do |raw, i|
            if i < 2
              out << C0.value(raw)
            else
              out.concat(Reference.new(nil, Record.level_of(raw)).path)
            end
          end
        end
      end
      out
    end

    # Compatibility: the group name of a plain reference.
    def group : Bytes
      group_name || raise Error.new("reference is a pattern, not a group")
    end
  end
end
