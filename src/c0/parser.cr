module C0
  # The one parser of the base grammar (GRAMMAR.md). It walks a buffer,
  # raises on the first structural error, builds the document model with
  # dead elements dropped, notes every canonical violation when asked, and
  # counts the dead elements met in bodies for tools above the format.
  # `Body`, `Document`, `Container`, `Validator` and the stream reader are
  # all built on it.
  #
  # Body level is a flat state machine over lines (file line, group line,
  # header row, record, note, commit); records and their values are
  # recursive, since a level holds a body.
  class Parser
    getter warnings : Array(String)     # canonical violations, when checking canonicality
    getter dead_elements : Int32        # dead elements met in bodies (the heading's dead keys are not counted)

    @buf : Bytes
    @len : Int32
    @canonical : Bool
    @ok : Bool
    # Regions to jump over at a block boundary, start => end: the damaged
    # blocks of a stream (see Stream::Reader).
    @skip : Hash(Int32, Int32)?

    def initialize(@buf : Bytes, canonical : Bool = false, skip : Hash(Int32, Int32)? = nil)
      @len = @buf.size.to_i32
      @canonical = canonical
      @skip = skip
      @ok = true
      @warnings = Array(String).new
      @dead_elements = 0
    end

    # Whether nothing non-canonical has been met.
    def ok? : Bool
      @ok
    end

    def not_canonical(why : String) : Nil
      @ok = false
      @warnings << why
    end

    # Jump over skipped regions beginning at pos.
    @[AlwaysInline]
    def skip(pos : Int32) : Int32
      if s = @skip
        while e = s[pos]?
          pos = e
        end
      end
      pos
    end

    # Skip layout (and skipped regions). Layout is a canonical violation.
    def layout(pos : Int32, stop : Int32) : Int32
      pos = skip(pos)
      p2 = Scan.layout(@buf, pos, stop)
      not_canonical("layout bytes") if p2 != pos
      skip(p2)
    end

    # ---- heading --------------------------------------------------------

    # After SYN. Returns the heading (dead keys dropped, duplicates kept)
    # and the position of the first body code.
    def heading(pos : Int32, stop : Int32) : {Heading, Int32}
      ptr = @buf.to_unsafe
      hs = pos
      pairs = Array({Bytes, Bytes}).new
      raw_pairs = Array({Bytes, Bytes}).new
      add = ->(key : Bytes, rawv : Bytes, at : Int32) do
        raw_pairs << {key, rawv}
        pairs << {key, rawv.size > 0 && rawv[0] == DLE ? rawv : C0.value(rawv)}
        check_schema(rawv, at) if key == "schema".to_slice
      end
      loop do
        pos = layout(pos, stop)
        break if pos >= stop
        b = ptr[pos]
        if b == SOH
          p2 = Scan.layout(@buf, pos + 1, stop)
          break if p2 < stop && ptr[p2] == RS # a header row begins the body
          key, vs, pos = keyed_unit(pos + 1, stop, heading: true)
          add.call(key, C0.trim(@buf[vs...pos]), vs)
        elsif b == BEL
          p2 = Scan.layout(@buf, pos + 1, stop)
          raise UnexpectedEndError.new("BEL at end of input", p2) if p2 >= stop
          c = ptr[p2]
          if c == SOH
            p3 = Scan.layout(@buf, p2 + 1, stop)
            break if p3 < stop && ptr[p3] == RS # a dead header row begins the body
            not_canonical("dead element")
            _key, _vs, pos = keyed_unit(p2 + 1, stop, heading: true)
          elsif c >= 0x20_u8 || c == STX
            not_canonical("comment")
            pos = note_content(p2, stop)
          elsif c == RS || c == GS || c == FS || c == DLE
            break # a dead body element
          else
            raise SyntaxError.new("BEL before a code that is not an element", p2)
          end
        elsif b == SUB
          p2 = Scan.layout(@buf, pos + 1, stop)
          raise SyntaxError.new("SUB at the end of input", pos) if p2 >= stop
          c = ptr[p2]
          raise SyntaxError.new("the heading's values take no sub-units", pos) if c == US
          break # SUB before a body code: the body's business
        elsif b >= 0x20_u8
          raise SyntaxError.new("plain text directly after SYN", pos)
        else
          break
        end
      end
      h = Heading.new(@buf[hs...pos], pairs)
      h.pairs_raw = raw_pairs
      {h, pos}
    end

    # The `schema` key: a plain name, or a level holding one keyed record
    # whose keys are drawn from name, url and hash (DESIGN.md, Start).
    private def check_schema(rawv : Bytes, at : Int32) : Nil
      t = C0.trim(rawv)
      raise SyntaxError.new("schema needs a value", at) if t.size == 0
      if t[0] == DLE
        body = Body.new(t, 1, Scan.level(t, 0) - 1, level: true)
        recs = body.bare? ? body.records : Array(Record).new
        raise SyntaxError.new("a schema level holds one keyed record", at) unless body.bare? && recs.size == 1
        rec = recs[0]
        raise SyntaxError.new("a schema level holds a keyed record, not a positional one", at) unless rec.keyed?
        pairs = rec.pairs
        raise SyntaxError.new("a schema record needs name, url or hash", at) if pairs.empty?
        pairs.each do |k, v|
          raise SyntaxError.new("unknown schema key '#{String.new(k)}'", at) unless k == "name".to_slice || k == "url".to_slice || k == "hash".to_slice
          raise SyntaxError.new("a schema #{String.new(k)} is a name", at) unless v.size > 0 && C0.name?(v)
        end
      elsif t[0] == STX
        raise SyntaxError.new("a schema name cannot be text", at)
      else
        v = C0.value(t)
        raise SyntaxError.new("a schema name is a name", at) unless v.size > 0 && C0.name?(v)
      end
    end

    # ---- body -----------------------------------------------------------

    # A body from pos to stop. At depth zero (level false) commits are legal
    # and the body ends at EOT, SYN, EM or stop; in a level it ends at CAN.
    # Returns the files (dead elements dropped) and the position of the
    # code that ended the body.
    def body(pos : Int32, stop : Int32, level : Bool) : {Array(FileView), Int32}
      ptr = @buf.to_unsafe
      files = Array(FileView).new
      file = FileView.new(@buf, 0, 0, Array(Group).new, leading: true)
      group = Group.new(@buf, 0, 0, 0, nil, Array(Record).new) # the unnamed group
      attached = false   # whether `group` is in file.groups
      header_ok = true   # a header row may still begin this group
      dead_file = false  # inside a dead file: everything to the next file line is discarded
      dead_depth = nil.as(Int32?) # inside a dead group of this depth
      dead = false       # BEL seen: the next element is dead
      prefix = 0         # SUB run read before a GS: the subsection's depth less one
      prev_depth = 0     # depth of the group line before, as written (dead or not)
      mark_at = pos      # position of that BEL, for errors

      # Add the unnamed group to its file once it has content.
      attach = ->{
        unless attached
          file.groups << group unless dead_file || dead_depth
          attached = true
        end
      }
      # Close the current file: an empty leading file is dropped when a
      # file line follows it.
      finish_file = ->{
        files << file unless dead_file || (file.leading? && file.groups.empty?)
      }

      loop do
        pos = layout(pos, stop)
        break if pos >= stop
        b = ptr[pos]
        case b
        when RS
          rec, pos = record(pos + 1, stop)
          if dead
            @dead_elements += 1
          else
            group.records << rec
            attach.call
            header_ok = false
          end
          dead = false
        when SOH
          p2 = Scan.layout(@buf, pos + 1, stop)
          raise SyntaxError.new("keyed unit outside a record", pos) unless p2 < stop && ptr[p2] == RS
          raise SyntaxError.new("header row not at the start of its group", pos) unless header_ok
          hdr, pos = header_row(p2 + 1, stop)
          if dead
            @dead_elements += 1
          else
            group.header = hdr
            attach.call
            header_ok = false
          end
          dead = false
        when GS
          depth = 1 + prefix
          prefix = 0
          if depth > prev_depth + 1
            raise SyntaxError.new("depth skipped: a group is at most one deeper than the group line before it", pos)
          end
          prev_depth = depth
          ns, ne, pos = name(layout(pos + 1, stop), stop)
          if (dd = dead_depth) && depth <= dd
            dead_depth = nil # the dead group's span ends here
          end
          if dead
            @dead_elements += 1
            dead_depth = depth unless dead_file || dead_depth
            group = Group.new(@buf, depth, ns, ne, nil, Array(Record).new)
            attached = true # a dead group is parsed, never attached
          elsif dead_file || dead_depth
            group = Group.new(@buf, depth, ns, ne, nil, Array(Record).new)
            attached = true
          else
            group = Group.new(@buf, depth, ns, ne, nil, Array(Record).new)
            file.groups << group
            attached = true
          end
          header_ok = true
          dead = false
        when FS
          ns, ne, pos = name(pos + 1, stop)
          finish_file.call
          if dead
            @dead_elements += 1
            dead_file = true
          else
            dead_file = false
          end
          file = FileView.new(@buf, ns, ne, Array(Group).new, leading: false)
          group = Group.new(@buf, 0, 0, 0, nil, Array(Record).new)
          attached = false
          dead_depth = nil
          prev_depth = 0
          header_ok = true
          dead = false
        when BEL
          raise SyntaxError.new("BEL before a code that is not an element", pos) if dead
          p2 = Scan.layout(@buf, pos + 1, stop)
          raise UnexpectedEndError.new("BEL at end of input", p2) if p2 >= stop
          c = ptr[p2]
          if c >= 0x20_u8 || c == STX
            not_canonical("comment")
            pos = note_content(p2, stop)
          elsif c == RS || c == SOH || c == GS || c == FS
            not_canonical("dead element")
            dead = true
            mark_at = pos
            pos = p2
          elsif c == SUB
            # BEL kills a group line whole, its SUB prefix included
            p3 = p2
            while p3 < stop && ptr[p3] == SUB
              p3 = Scan.layout(@buf, p3 + 1, stop)
            end
            if p3 < stop && ptr[p3] == GS
              not_canonical("dead element")
              dead = true
              mark_at = pos
              pos = p2
            elsif p3 < stop && ptr[p3] == US
              raise SyntaxError.new("BEL before a sub-unit: a unit cannot be dead", pos)
            else
              raise SyntaxError.new("BEL before a code that is not an element", p2)
            end
          elsif c == DLE
            raise SyntaxError.new("a nested level is not an item", p2)
          else
            raise SyntaxError.new("BEL before a code that is not an element", p2)
          end
        when SUB
          # A run of SUB before GS is the subsection's depth prefix; before
          # RS, FS or SOH it is reserved; a sub-unit (SUB US) lives inside
          # a record and never reaches here.
          start = pos
          run = 0
          while pos < stop && ptr[pos] == SUB
            run += 1
            pos = layout(pos + 1, stop)
          end
          raise SyntaxError.new("SUB at the end of input", start) if pos >= stop
          c = ptr[pos]
          if c == GS
            prefix = run
          elsif c == RS
            raise SyntaxError.new("SUB before RS is reserved (a sub-record)", start)
          elsif c == FS
            raise SyntaxError.new("SUB before FS is reserved (a sub-file)", start)
          elsif c == SOH
            raise SyntaxError.new("SUB before SOH is reserved (a sub-key); a header row admits none", start)
          elsif c == US
            raise SyntaxError.new("US outside a record", pos)
          elsif c == BEL
            raise SyntaxError.new("SUB before BEL", start)
          else
            raise SyntaxError.new("SUB before a byte that is not a separator", start)
          end
        when ETB
          raise SyntaxError.new("commit inside a nested level", pos) if level
          raise SyntaxError.new("BEL before ETB: framing cannot be commented out", mark_at) if dead
          not_canonical("commit")
          pos = Scan.plain(@buf, layout(pos + 1, stop), stop)
        when EOT, SYN, EM
          raise SyntaxError.new("framing inside open level", pos) if level
          raise SyntaxError.new("BEL before framing", mark_at) if dead
          break
        when CAN
          raise SyntaxError.new("CAN with no open level", pos) unless level
          raise SyntaxError.new("BEL before CAN", mark_at) if dead
          break
        when US
          raise SyntaxError.new("US outside a record", pos)
        when STX
          raise SyntaxError.new("text outside a record", pos)
        when DLE
          raise SyntaxError.new("a nested level is not an item", pos)
        when ENQ
          raise SyntaxError.new("a reference outside a record", pos)
        else
          if b >= 0x20_u8
            raise SyntaxError.new("plain text outside a record", pos)
          end
          raise UnassignedCodeError.new(b, pos)
        end
      end
      files << file unless dead_file || (file.leading? && file.groups.empty? && !files.empty?)
      # A body whose every element is dead is an empty body: one empty
      # leading file, so `files` is never empty.
      files << FileView.new(@buf, 0, 0, Array(Group).new, leading: true) if files.empty?
      {files, pos}
    end

    # A label or path: plain, never text. Returns {name start, name end, pos}.
    private def name(pos : Int32, stop : Int32) : {Int32, Int32, Int32}
      ptr = @buf.to_unsafe
      pos = layout(pos, stop)
      raise SyntaxError.new("a name cannot be text", pos) if pos < stop && ptr[pos] == STX
      ns = pos
      pos = Scan.plain(@buf, pos, stop)
      ne = pos
      while ne > ns && C0.layout?(ptr[ne - 1])
        ne -= 1
      end
      not_canonical("layout bytes") if ne != pos
      {ns, ne, pos}
    end

    # After SOH RS: names, each followed by notes, separated by US.
    private def header_row(pos : Int32, stop : Int32) : {Record, Int32}
      ptr = @buf.to_unsafe
      start = pos
      loop do
        _ns, _ne, pos = name(pos, stop)
        pos = trailing_notes(layout(pos, stop), stop)
        break unless pos < stop && ptr[pos] == US
        pos += 1
      end
      if pos < stop && ptr[pos] == SUB
        p2 = Scan.layout(@buf, pos + 1, stop)
        raise SyntaxError.new("a header row admits no sub-units", pos) if p2 < stop && ptr[p2] == US
      end
      {Record.new(@buf, start, trim_end(start, pos)), pos}
    end

    # ---- records --------------------------------------------------------

    # After RS. Returns the record and the position after it.
    def record(pos : Int32, stop : Int32) : {Record, Int32}
      start = pos
      pos = keyed_start?(pos, stop) ? keyed(pos, stop) : positional(pos, stop)
      {Record.new(@buf, start, trim_end(start, pos)), pos}
    end

    # Does the record starting here begin with a keyed unit, live or dead?
    private def keyed_start?(pos : Int32, stop : Int32) : Bool
      ptr = @buf.to_unsafe
      loop do
        pos = Scan.layout(@buf, pos, stop)
        return false if pos >= stop
        b = ptr[pos]
        if b == SOH
          p2 = Scan.layout(@buf, pos + 1, stop)
          return !(p2 < stop && ptr[p2] == RS)
        elsif b == BEL
          p2 = Scan.layout(@buf, pos + 1, stop)
          return false if p2 >= stop
          c = ptr[p2]
          if c == SOH
            p3 = Scan.layout(@buf, p2 + 1, stop)
            return !(p3 < stop && ptr[p3] == RS)
          end
          return false unless c >= 0x20_u8 || c == STX
          pos = note_content(p2, stop) # a note: look past it
        else
          return false
        end
      end
    end

    private def positional(pos : Int32, stop : Int32) : Int32
      ptr = @buf.to_unsafe
      loop do
        pos = value(pos, stop, heading: false)
        pos = sub_units(pos, stop)
        pos = layout(pos, stop)
        break if pos >= stop
        b = ptr[pos]
        if b == US
          pos += 1
        elsif b == SUB
          break # a prefix before the next line: the body's business
        elsif b == SOH
          p2 = Scan.layout(@buf, pos + 1, stop)
          break if p2 < stop && ptr[p2] == RS # a header row ends the record
          raise SyntaxError.new("keyed unit in a positional record (mixed record)", pos)
        else
          break
        end
      end
      pos
    end

    private def keyed(pos : Int32, stop : Int32) : Int32
      ptr = @buf.to_unsafe
      keys = Array(Bytes).new # the result's keys
      loop do
        pos = layout(pos, stop)
        break if pos >= stop
        b = ptr[pos]
        if b == SOH
          p2 = Scan.layout(@buf, pos + 1, stop)
          break if p2 < stop && ptr[p2] == RS
          key, _vs, pos = keyed_unit(pos + 1, stop, heading: false)
          pos = sub_units(pos, stop)
          keys << key
        elsif b == BEL
          p2 = Scan.layout(@buf, pos + 1, stop)
          raise UnexpectedEndError.new("BEL at end of input", p2) if p2 >= stop
          c = ptr[p2]
          if c == SOH
            p3 = Scan.layout(@buf, p2 + 1, stop)
            break if p3 < stop && ptr[p3] == RS
            not_canonical("dead element")
            _key, _vs, pos = keyed_unit(p2 + 1, stop, heading: false)
          elsif c >= 0x20_u8 || c == STX
            pos = trailing_notes(pos, stop)
          elsif c == SUB
            raise SyntaxError.new("BEL before a sub-unit: a unit cannot be dead", p2)
          else
            break
          end
        elsif b == SUB
          break # a prefix before the next line: the body's business
        else
          break
        end
      end
      raise SyntaxError.new("US after a keyed value (mixed record)", pos) if pos < stop && ptr[pos] == US
      seen = Set(Bytes).new
      keys.each { |k| not_canonical("duplicate key") unless seen.add?(k) }
      pos
    end

    # After SOH (not a header row). Returns {key, value start, pos after the value}.
    private def keyed_unit(pos : Int32, stop : Int32, heading : Bool) : {Bytes, Int32, Int32}
      ptr = @buf.to_unsafe
      ks, ke, pos = name(pos, stop)
      raise SyntaxError.new("key without a value (no US)", pos) unless pos < stop && ptr[pos] == US
      vs = pos + 1
      pos = value(vs, stop, heading: heading)
      {@buf[ks...ke], vs, pos}
    end

    # The sub-units after a unit's value: runs of SUB then US then a value,
    # each run's length the sub-unit's depth, at most one deeper than the
    # sub-unit before it. Returns the position after the last; a SUB that
    # prefixes a line code is left for the body, a reserved grain raised.
    private def sub_units(pos : Int32, stop : Int32) : Int32
      ptr = @buf.to_unsafe
      prev = 0
      loop do
        p = layout(pos, stop)
        return pos unless p < stop && ptr[p] == SUB
        start = p
        run = 0
        while p < stop && ptr[p] == SUB
          run += 1
          p = layout(p + 1, stop)
        end
        raise SyntaxError.new("SUB at the end of input", start) if p >= stop
        c = ptr[p]
        if c == US
          raise SyntaxError.new("depth skipped: a sub-unit is at most one deeper than the sub-unit before it", start) if run > prev + 1
          prev = run
          pos = value(p + 1, stop, heading: false)
        elsif c == RS || c == GS || c == FS
          return pos # the body's business
        elsif c == SOH
          p2 = Scan.layout(@buf, p + 1, stop)
          raise SyntaxError.new("a header row admits no SUB", start) if p2 < stop && ptr[p2] == RS
          raise SyntaxError.new("SUB before SOH is reserved (a sub-key)", start)
        elsif c == BEL
          raise SyntaxError.new("SUB before BEL", start)
        else
          raise SyntaxError.new("SUB before a byte that is not a separator", start)
        end
      end
    end

    # ---- values ---------------------------------------------------------

    # One unit's value, possibly empty, with the notes after it. Returns
    # the position of the next code at this depth.
    private def value(pos : Int32, stop : Int32, heading : Bool) : Int32
      ptr = @buf.to_unsafe
      pos = layout(pos, stop)
      return pos if pos >= stop
      b = ptr[pos]
      if b >= 0x20_u8
        pos = Scan.plain(@buf, pos, stop)
        not_canonical("layout bytes") if ptr[pos - 1] == SP
      elsif b == STX
        start = pos
        pos = Scan.text(@buf, pos, stop)
        if @canonical
          inside = @buf[(start + 1)...(pos - 1)]
          not_canonical("empty text") if inside.size == 0
          not_canonical("gratuitous text") if inside.size > 0 && C0.plain?(C0.decode_text(inside))
        end
      elsif b == DLE
        _files, pos = level(pos, stop)
      elsif b == ENQ
        raise SyntaxError.new("reference in a heading", pos) if heading
        _ref, pos = reference(pos, stop)
      elsif b == BEL
        p2 = Scan.layout(@buf, pos + 1, stop)
        raise UnexpectedEndError.new("BEL at end of input", p2) if p2 >= stop
        c = ptr[p2]
        if c == DLE
          not_canonical("dead element") # a dead level: the unit is empty
          _files, pos = level(p2, stop)
        elsif c >= 0x20_u8 || c == STX
          pos = trailing_notes(pos, stop)
          raise SyntaxError.new("value after a note in the same unit", pos) if value_start?(pos, stop)
          return pos
        else
          return pos # a dead element after this empty unit: the caller's business
        end
      else
        return pos # an empty unit
      end
      after = trailing_notes(layout(pos, stop), stop)
      raise SyntaxError.new("two values in one unit", after) if value_start?(after, stop)
      after
    end

    @[AlwaysInline]
    private def value_start?(pos : Int32, stop : Int32) : Bool
      return false unless pos < stop
      b = @buf[pos]
      b >= 0x20_u8 || b == STX || b == DLE || b == ENQ
    end

    # The content of a note, from the byte after BEL and layout.
    private def note_content(pos : Int32, stop : Int32) : Int32
      @buf[pos] == STX ? Scan.text(@buf, pos, stop) : Scan.plain(@buf, pos, stop)
    end

    # Notes after a value. A BEL before a code is left for the caller.
    private def trailing_notes(pos : Int32, stop : Int32) : Int32
      ptr = @buf.to_unsafe
      while pos < stop && ptr[pos] == BEL
        p2 = Scan.layout(@buf, pos + 1, stop)
        raise UnexpectedEndError.new("BEL at end of input", p2) if p2 >= stop
        c = ptr[p2]
        break unless c >= 0x20_u8 || c == STX
        not_canonical("comment")
        pos = layout(note_content(p2, stop), stop)
      end
      pos
    end

    # DLE at pos: a nested level. Returns its files and the position after CAN.
    def level(pos : Int32, stop : Int32) : {Array(FileView), Int32}
      ptr = @buf.to_unsafe
      start = pos
      pos = layout(pos + 1, stop)
      raise UnexpectedEndError.new("level opened at #{start} is not closed", pos) if pos >= stop
      b = ptr[pos]
      return {[FileView.new(@buf, 0, 0, Array(Group).new, leading: true)], pos + 1} if b == CAN
      unless b == FS || b == GS || b == RS || b == SOH || b == BEL || b == SUB
        raise SyntaxError.new("DLE must be followed by a structural code", pos)
      end
      files, pos = body(pos, stop, level: true)
      pos = layout(pos, stop)
      raise UnexpectedEndError.new("level opened at #{start} is not closed", pos) if pos >= stop
      raise SyntaxError.new("unexpected byte inside level", pos) unless ptr[pos] == CAN
      {files, pos + 1}
    end

    # ENQ at pos: a group name, or a pattern (DESIGN.md, References).
    # Returns the reference and the position after it.
    def reference(pos : Int32, stop : Int32) : {Reference, Int32}
      ptr = @buf.to_unsafe
      at = pos
      pos = layout(pos + 1, stop)
      raise SyntaxError.new("reference without a name", at) if pos >= stop
      b = ptr[pos]
      if b == DLE
        dead0 = @dead_elements
        files, after = level(pos, stop)
        raise SyntaxError.new("a dead element is not a step of a pattern", pos) if @dead_elements != dead0
        body = Body.new(@buf, pos + 1, after - 1, files)
        check_pattern(body, pos, inner: false)
        {Reference.new(nil, body), after}
      elsif b == STX
        raise SyntaxError.new("a reference is a name or a pattern, not text", pos)
      elsif b >= 0x20_u8
        ns, ne, pos = name(pos, stop)
        raise SyntaxError.new("reference without a name", at) if ne == ns
        {Reference.new(@buf[ns...ne], nil), pos}
      else
        raise SyntaxError.new("reference without a name", at)
      end
    end

    # A pattern is one branch of the target with its values left out.
    # `inner` is a pattern continued into a level, whose records may stand
    # in the unnamed group.
    protected def check_pattern(body : Body, at : Int32, inner : Bool) : Nil
      files = body.files
      raise SyntaxError.new("a pattern is one branch: two files", at) if files.size > 1
      groups = files[0].groups
      raise SyntaxError.new(inner ? "an empty level continues nothing" : "an empty level is not a reference", at) if groups.empty?
      raise SyntaxError.new("a pattern begins with a file or group line", at) if !inner && groups[0].depth == 0
      prev = -1
      groups.each_with_index do |g, i|
        raise SyntaxError.new("a header row is not a step of a pattern", at) if g.has_header?
        raise SyntaxError.new("a pattern is one branch: two groups at one depth", at) unless g.depth > prev
        prev = g.depth
        raise SyntaxError.new("nothing follows the record in a pattern", at) if i < groups.size - 1 && !g.records.empty?
      end
      recs = groups.last.records
      raise SyntaxError.new("a pattern is one branch: two records", at) if recs.size > 1
      if recs.empty?
        not_canonical("group reference written as a pattern") unless inner
        return
      end
      rec = recs[0]
      if rec.keyed?
        pairs = rec.pairs
        raise SyntaxError.new("a keyed record in a pattern holds one keyed unit", at) unless pairs.size == 1
        raise SyntaxError.new("a keyed unit in a pattern has no value", at) unless pairs[0][1].size == 0
        raise SyntaxError.new("a step of a pattern is a name", at) unless pairs[0][0].size > 0 && C0.name?(pairs[0][0])
        return
      end
      units = rec.fields
      raise SyntaxError.new("a pattern record holds at most a record id, a field name and a level", at) if units.size > 3
      units.each_with_index do |raw, i|
        t = C0.trim(raw)
        if i == 2
          raise SyntaxError.new("the third unit of a pattern record is a level", at) unless t.size > 0 && t[0] == DLE
          check_pattern(Record.level_of(t), at, inner: true)
        else
          raise SyntaxError.new("a step of a pattern is a name", at) if t.size > 0 && (t[0] == DLE || t[0] == ENQ || t[0] == STX)
          v = C0.value(t)
          raise SyntaxError.new("a step of a pattern is a name", at) unless v.size > 0 && C0.name?(v)
        end
      end
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
end
