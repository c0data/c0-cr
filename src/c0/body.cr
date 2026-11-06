module C0
  # Zero-copy navigator for a document body: the bytes between a heading
  # and EOT, or the inside of a nested level. Indexes files, groups,
  # header rows and records once; everything it returns is a slice into
  # the original buffer.
  #
  # Records before the first GS of a file form an unnamed group; records
  # and groups before the first FS form an unnamed file.
  struct Body
    getter buf : Bytes
    getter start : Int32
    getter stop : Int32
    getter files : Array(FileView)

    def initialize(@buf : Bytes, @start : Int32 = 0, @stop : Int32 = buf.size.to_i32)
      @files = Array(FileView).new
      index
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
      @files.size == 1 && @files[0].name.empty? && @files[0].groups.size <= 1 &&
        (@files[0].groups.empty? || @files[0].groups[0].depth == 0)
    end

    private def first_file : FileView
      @files[0]
    end

    def raw : Bytes
      @buf[@start...@stop]
    end

    # ------------------------------------------------------------------
    private def index : Nil
      ptr = @buf.to_unsafe
      pos = Scan.layout(@buf, @start, @stop)
      # leading unnamed file
      file_start = pos
      file = FileView.new(@buf, 0, 0, Array(Group).new)
      pos = index_part(pos, file)
      @files << file unless file.groups.empty? && pos < @stop && (ptr[pos] == FS || dead_fs?(pos))
      @files << file if @files.empty? && !(pos < @stop && (ptr[pos] == FS || dead_fs?(pos)))
      while pos < @stop
        b = ptr[pos]
        dead = false
        if b == BEL && dead_fs?(pos)
          dead = true
          pos = Scan.layout(@buf, pos + 1, @stop)
          b = FS
        end
        break unless b == FS
        pos = Scan.layout(@buf, pos + 1, @stop)
        ns = pos
        pos = Scan.plain(@buf, pos, @stop)
        ne = pos
        if dead
          # a dead file line is read as if absent: what follows belongs to
          # the file before it, its leading items to that file's last group
          prev = @files.last?
          unless prev
            prev = file
            @files << file
          end
          pos = index_part(pos, prev, prev.groups.last?)
        else
          f = FileView.new(@buf, ns, ne, Array(Group).new)
          pos = index_part(pos, f)
          @files << f
        end
      end
      @files << FileView.new(@buf, 0, 0, Array(Group).new) if @files.empty?
    end

    private def dead_fs?(pos : Int32) : Bool
      ptr = @buf.to_unsafe
      return false unless pos < @stop && ptr[pos] == BEL
      p2 = Scan.layout(@buf, pos + 1, @stop)
      p2 < @stop && ptr[p2] == FS
    end

    # Index one part: leading items (unnamed group), then groups. Returns
    # the position of the next FS (or dead FS), or @stop.
    private def index_part(pos : Int32, file : FileView, cont : Group? = nil) : Int32
      ptr = @buf.to_unsafe
      # leading items: the unnamed group, or `cont` when continuing after a
      # dead file line
      g = cont || Group.new(@buf, 0, 0, 0, nil, Array(Record).new)
      pos = index_group_contents(pos, g)
      file.groups << g if cont.nil? && (g.header || !g.records.empty?)
      current = g
      while pos < @stop
        b = ptr[pos]
        dead = false
        if b == BEL
          p2 = Scan.layout(@buf, pos + 1, @stop)
          if p2 < @stop && ptr[p2] == GS
            dead = true
            pos = p2
            b = GS
          else
            break
          end
        end
        break unless b == GS
        depth = 0
        while pos < @stop && (ptr[pos] == GS || C0.layout?(ptr[pos]))
          depth += 1 if ptr[pos] == GS
          pos += 1
        end
        ns = pos
        pos = Scan.plain(@buf, pos, @stop)
        ne = pos
        if dead
          # a dead group line: what follows still belongs to the group before
          pos = index_group_contents(pos, current)
          file.groups << current if current.same?(g) && !file.groups.any?(&.same?(g)) && (g.header || !g.records.empty?)
        else
          grp = Group.new(@buf, depth, ns, ne, nil, Array(Record).new)
          pos = index_group_contents(pos, grp)
          file.groups << grp
          current = grp
        end
      end
      pos
    end

    # After a group label (or at the start of a part): notes, header row,
    # items. Returns position of the next GS/FS/BEL-dead-GS/FS or stop.
    private def index_group_contents(pos : Int32, grp : Group) : Int32
      ptr = @buf.to_unsafe
      first_item = true
      loop do
        pos = Scan.layout(@buf, pos, @stop)
        break if pos >= @stop
        b = ptr[pos]
        if b == RS
          first_item = false
          rs = pos + 1
          pos = Scan.record_end(@buf, rs, @stop)
          grp.records << Record.new(@buf, rs, trim_end(rs, pos))
        elsif b == SOH
          p2 = Scan.layout(@buf, pos + 1, @stop)
          raise SyntaxError.new("keyed unit outside a record", pos) unless p2 < @stop && ptr[p2] == RS
          raise SyntaxError.new("header row not at the start of its group", pos) unless first_item
          first_item = false
          hs = p2 + 1
          pos = Scan.record_end(@buf, hs, @stop)
          grp.header = Record.new(@buf, hs, trim_end(hs, pos))
        elsif b == ETB
          pos = Scan.plain(@buf, Scan.layout(@buf, pos + 1, @stop), @stop)
        elsif b == BEL
          p2 = Scan.layout(@buf, pos + 1, @stop)
          if p2 >= @stop || ptr[p2] >= 0x20_u8 || ptr[p2] == STX
            pos = Scan.comment(@buf, pos, @stop) # a note
          elsif ptr[p2] == RS || ptr[p2] == SOH
            pos = Scan.comment(@buf, pos, @stop) # dead record / header row / keyed unit
            first_item = false if ptr[p2] == RS
          else
            break # dead GS or FS: the caller's business
          end
        else
          break
        end
      end
      pos
    end

    @[AlwaysInline]
    private def trim_end(start : Int32, stop : Int32) : Int32
      ptr = @buf.to_unsafe
      while stop > start && C0.layout?(ptr[stop - 1])
        stop -= 1
      end
      stop
    end
  end

  # A file within a body: its name and groups.
  struct FileView
    @buf : Bytes
    @name_start : Int32
    @name_end : Int32
    getter groups : Array(Group)

    def initialize(@buf : Bytes, @name_start : Int32, @name_end : Int32, @groups : Array(Group))
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

  # A record: positional or keyed. Zero-copy accessors.
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

    # Whether the record is keyed (its first unit is an SOH).
    def keyed? : Bool
      ptr = @buf.to_unsafe
      p = Scan.layout(@buf, @start, @end)
      while p < @end && ptr[p] == BEL
        p2 = Scan.layout(@buf, p + 1, @end)
        return true if p2 < @end && ptr[p2] == SOH
        break if p2 < @end && ptr[p2] < 0x20_u8 && ptr[p2] != STX && ptr[p2] != DLE
        p = Scan.layout(@buf, Scan.comment(@buf, p, @end), @end)
      end
      p < @end && ptr[p] == SOH
    end

    # ---- positional -----------------------------------------------------

    # Raw slice of unit n (layout at its edges included).
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
      Body.new(t, 1, stop - 1)
    end

    # Yields (index, start, end) for each positional unit.
    private def each_unit_range(& : Int32, Int32, Int32 ->) : Nil
      ptr = @buf.to_unsafe
      pos = Scan.layout(@buf, @start, @end)
      return if pos < @end && ptr[pos] == SOH
      idx = 0
      unit_start = @start
      loop do
        pos = Scan.unit(@buf, pos, @end)
        yield idx, unit_start, pos
        break unless pos < @end && ptr[pos] == US
        idx += 1
        pos += 1
        unit_start = pos
      end
    end

    # Yields (key, key_start, key_end, value_start, value_end) per keyed unit.
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
          yield C0.trim(@buf[ks...ke]), ks, ke, vs, ve
          pos = ve
        elsif b == BEL
          pos = Scan.comment(@buf, pos, @end)
        elsif C0.layout?(b)
          pos += 1
        else
          return
        end
      end
    end
  end

  # A reference: a group name, or a path of two or three segments.
  struct Reference
    getter path : Array(Bytes)

    def initialize(@path : Array(Bytes))
    end

    def self.parse(raw : Bytes) : Reference
      t = C0.trim(raw)
      raise Error.new("unit is not a reference") unless t.size > 0 && t[0] == ENQ
      p = Scan.layout(t, 1)
      if p < t.size && t[p] == STX
        stop = Scan.text(t, p)
        inside = C0.decode_text(t[(p + 1)...(stop - 1)])
        segs = Array(Bytes).new
        s = 0
        i = 0
        while i < inside.size
          if inside[i] == US
            segs << inside[s...i]
            s = i + 1
          end
          i += 1
        end
        segs << inside[s...inside.size]
        raise SyntaxError.new("reference path with more than three segments", p) if segs.size > 3
        raise SyntaxError.new("reference path with an empty segment", p) if segs.any?(&.empty?)
        raise SyntaxError.new("reference path segment is not a name", p) unless segs.all? { |s| C0.name?(s) }
        Reference.new(segs)
      else
        name = C0.trim(t[p...t.size])
        raise SyntaxError.new("reference without a name", p) if name.empty?
        raise SyntaxError.new("reference name is not a name", p) unless C0.name?(name)
        Reference.new([name])
      end
    end

    def group : Bytes
      @path[0]
    end

    def record : Bytes?
      @path[1]?
    end

    def field : Bytes?
      @path[2]?
    end

    def group? : Bool
      @path.size == 1
    end
  end
end
