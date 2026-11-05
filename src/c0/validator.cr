module C0
  # Recursive-descent check of a buffer against GRAMMAR.md. `validate`
  # raises the first error; `canonical?` additionally applies the
  # canonical constraints and answers false instead of raising.
  struct Validator
    getter warnings : Array(String)

    @buf : Bytes
    @len : Int32
    @canonical : Bool
    @ok : Bool
    @diff : Bool

    def initialize(@buf : Bytes, canonical : Bool = false)
      @len = @buf.size.to_i32
      @canonical = canonical
      @ok = true
      @diff = false
      @warnings = Array(String).new
    end

    # Raise on the first structural error.
    def self.validate(buf : Bytes) : Nil
      Validator.new(buf).run
    end

    # Well-formed and canonical: no layout, one spelling per value, keyed
    # records sorted and unique, no framing, no comments.
    def self.canonical?(buf : Bytes) : Bool
      v = Validator.new(buf, canonical: true)
      begin
        v.run
      rescue Error
        return false
      end
      v.ok?
    end

    def ok? : Bool
      @ok
    end

    private def not_canonical(why : String) : Nil
      @ok = false
      @warnings << why
    end

    def run : Nil
      ptr = @buf.to_unsafe
      pos = 0
      pos = layout(pos)
      first = true
      while pos < @len
        byte = ptr[pos]
        if byte == SYN
          not_canonical("SYN in a canonical unit")
          pos = heading(pos + 1)
          first = true # the body that follows belongs to this document
        elsif byte == EM
          not_canonical("EM in a canonical unit")
          return # raw region follows
        else
          raise SyntaxError.new("a document after the first must begin with SYN", pos) unless first
          pos = body(pos, @len, depth0: true)
          # after a body only EOT, SYN, EM or end
          pos = layout(pos)
          first = false
          if pos < @len
            b = ptr[pos]
            if b == EOT
              not_canonical("EOT in a canonical unit")
              pos = layout(pos + 1)
              if pos < @len && ptr[pos] != SYN && ptr[pos] != EM
                raise SyntaxError.new("unexpected byte after EOT", pos)
              end
            elsif b == SYN || b == EM
              next
            else
              raise SyntaxError.new("unexpected byte after document", pos)
            end
          end
        end
      end
    end

    @[AlwaysInline]
    private def layout(pos : Int32, stop : Int32 = @len) : Int32
      p2 = Scan.layout(@buf, pos, stop)
      not_canonical("layout bytes") if p2 != pos
      p2
    end

    # Heading: keyed units and notes after SYN. Returns position of the
    # first body code. Also decides diff vs data body.
    private def heading(pos : Int32) : Int32
      ptr = @buf.to_unsafe
      keys = Array(Bytes).new
      pos = layout(pos)
      while pos < @len
        b = ptr[pos]
        if b == SOH
          p2 = layout(pos + 1)
          break if p2 < @len && ptr[p2] == RS # header row ends the heading
          k, v, pos = keyed_unit(pos + 1, @len, heading: true)
          keys << k
          @diff = true if k == "shape".to_slice && v == "diff".to_slice
        elsif b == BEL
          pos = comment(pos, @len, allow_dead: true)
        elsif b >= 0x20_u8
          raise SyntaxError.new("plain text directly after SYN", pos)
        else
          break
        end
        pos = layout(pos)
      end
      check_keys(keys)
      pos
    end

    private def check_keys(keys : Array(Bytes)) : Nil
      (1...keys.size).each do |i|
        c = keys[i - 1] <=> keys[i]
        not_canonical("duplicate key") if c == 0
        not_canonical("keys out of order") if c > 0
      end
    end

    # A body (data or diff) from pos to stop. depth0 allows commits.
    private def body(pos : Int32, stop : Int32, depth0 : Bool) : Int32
      return diff_body(pos, stop) if @diff && depth0
      ptr = @buf.to_unsafe
      pos = layout(pos, stop)
      pos = part(pos, stop, depth0)
      while pos < stop
        b = ptr[pos]
        if b == FS
          pos = plain_name(pos + 1, stop)
          pos = part(pos, stop, depth0)
        elsif b == BEL
          p2 = Scan.layout(@buf, pos + 1, stop)
          if p2 < stop && ptr[p2] == FS
            not_canonical("dead element")
            pos = plain_name(p2 + 1, stop)
            pos = part(pos, stop, depth0)
          else
            break
          end
        else
          break
        end
      end
      pos
    end

    # part = *note [header-row] *item *group
    private def part(pos : Int32, stop : Int32, depth0 : Bool) : Int32
      ptr = @buf.to_unsafe
      pos = pre(pos, stop, depth0)
      pos = header_row?(pos, stop)
      pos = items(pos, stop, depth0)
      while pos < stop
        b = ptr[pos]
        if b == GS
          pos = group(pos, stop, depth0)
        elsif b == BEL
          p2 = Scan.layout(@buf, pos + 1, stop)
          if p2 < stop && ptr[p2] == GS
            not_canonical("dead element")
            pos = group(p2, stop, depth0)
          else
            break
          end
        else
          break
        end
      end
      pos
    end

    private def group(pos : Int32, stop : Int32, depth0 : Bool) : Int32
      ptr = @buf.to_unsafe
      while pos < stop && ptr[pos] == GS
        pos = layout(pos + 1, stop)
      end
      pos = plain_name(pos, stop)
      pos = pre(pos, stop, depth0)
      pos = header_row?(pos, stop)
      items(pos, stop, depth0)
    end

    # Before a header row: notes, commits (at depth zero), dead records and
    # dead header rows.
    private def pre(pos : Int32, stop : Int32, depth0 : Bool) : Int32
      ptr = @buf.to_unsafe
      loop do
        pos = layout(pos, stop)
        break if pos >= stop
        b = ptr[pos]
        if b == ETB
          raise SyntaxError.new("commit inside a nested level", pos) unless depth0
          not_canonical("commit")
          pos = Scan.plain(@buf, layout(pos + 1, stop), stop)
        elsif b == BEL
          p2 = Scan.layout(@buf, pos + 1, stop)
          raise UnexpectedEndError.new("BEL at end of input", p2) if p2 >= stop
          if ptr[p2] >= 0x20_u8 || ptr[p2] == STX
            pos = notes(pos, stop)
          elsif ptr[p2] == RS
            not_canonical("dead element")
            pos = record(p2 + 1, stop)
          elsif ptr[p2] == SOH
            p3 = Scan.layout(@buf, p2 + 1, stop)
            if p3 < stop && ptr[p3] == RS
              not_canonical("dead element")
              pos = header_names(p3 + 1, stop)
            else
              raise SyntaxError.new("keyed unit outside a record", p2)
            end
          else
            break
          end
        else
          break
        end
      end
      pos
    end

    private def header_names(pos : Int32, stop : Int32) : Int32
      ptr = @buf.to_unsafe
      pos = layout(pos, stop)
      loop do
        pos = plain_name(pos, stop)
        break unless pos < stop && ptr[pos] == US
        pos = layout(pos + 1, stop)
      end
      pos
    end

    # Notes only (BEL followed by plain/text); dead elements are handled
    # by their element rules.
    private def notes(pos : Int32, stop : Int32) : Int32
      ptr = @buf.to_unsafe
      loop do
        pos = layout(pos, stop)
        break unless pos < stop && ptr[pos] == BEL
        p2 = Scan.layout(@buf, pos + 1, stop)
        raise UnexpectedEndError.new("BEL at end of input", p2) if p2 >= stop
        break if ptr[p2] < 0x20_u8 && ptr[p2] != STX # a dead element, not a note
        not_canonical("comment")
        pos = p2 < stop ? Scan.plain(@buf, p2, stop) : p2
        if p2 < stop && ptr[p2] == STX
          pos = Scan.text(@buf, p2, stop)
        end
      end
      pos
    end

    private def header_row?(pos : Int32, stop : Int32) : Int32
      ptr = @buf.to_unsafe
      pos = layout(pos, stop)
      return pos unless pos < stop && ptr[pos] == SOH
      p2 = layout(pos + 1, stop)
      return pos unless p2 < stop && ptr[p2] == RS
      header_names(p2 + 1, stop)
    end

    private def items(pos : Int32, stop : Int32, depth0 : Bool) : Int32
      ptr = @buf.to_unsafe
      loop do
        pos = layout(pos, stop)
        break if pos >= stop
        b = ptr[pos]
        if b == RS
          pos = record(pos + 1, stop)
        elsif b == ETB
          raise SyntaxError.new("commit inside a nested level", pos) unless depth0
          not_canonical("commit")
          pos = Scan.plain(@buf, layout(pos + 1, stop), stop)
        elsif b == BEL
          p2 = Scan.layout(@buf, pos + 1, stop)
          if p2 >= stop || ptr[p2] >= 0x20_u8 || ptr[p2] == STX
            pos = notes(pos, stop)
          elsif ptr[p2] == RS
            not_canonical("dead element")
            pos = record(p2 + 1, stop)
          elsif ptr[p2] == SOH
            p3 = Scan.layout(@buf, p2 + 1, stop)
            if p3 < stop && ptr[p3] == RS
              not_canonical("dead element")
              pos = header_names(p3 + 1, stop)
            else
              raise SyntaxError.new("keyed unit outside a record", p2)
            end
          elsif ptr[p2] == DLE
            raise SyntaxError.new("a nested level is not an item", p2)
          else
            break # dead GS/FS handled by caller; others are errors there
          end
        elsif b == SOH
          p2 = Scan.layout(@buf, pos + 1, stop)
          raise SyntaxError.new("header row not at the start of its group", pos) if p2 < stop && ptr[p2] == RS
          raise SyntaxError.new("keyed unit outside a record", pos)
        else
          break
        end
      end
      pos
    end

    # After RS. Returns position after the record.
    private def record(pos : Int32, stop : Int32) : Int32
      ptr = @buf.to_unsafe
      pos = layout(pos, stop)
      if keyed_start?(pos, stop)
        keys = Array(Bytes).new
        loop do
          pos = layout(pos, stop)
          break if pos >= stop
          b = ptr[pos]
          if b == SOH
            p2 = Scan.layout(@buf, pos + 1, stop)
            break if p2 < stop && ptr[p2] == RS
            k, _v, pos = keyed_unit(pos + 1, stop, heading: false)
            keys << k
          elsif b == BEL
            p2 = Scan.layout(@buf, pos + 1, stop)
            raise UnexpectedEndError.new("BEL at end of input", p2) if p2 >= stop
            if ptr[p2] == SOH
              p3 = Scan.layout(@buf, p2 + 1, stop)
              break if p3 < stop && ptr[p3] == RS
              not_canonical("dead element")
              _k, _v, pos = keyed_unit(p2 + 1, stop, heading: false)
            elsif ptr[p2] >= 0x20_u8 || ptr[p2] == STX
              pos = notes(pos, stop)
            else
              break
            end
          else
            break
          end
        end
        check_keys(keys)
        raise SyntaxError.new("US after a keyed value (mixed record)", pos) if pos < stop && ptr[pos] == US
        return pos
      end
      # positional
      loop do
        pos = value(pos, stop)
        pos = layout(pos, stop)
        break if pos >= stop
        b = ptr[pos]
        if b == US
          pos = pos + 1
        elsif b == SOH
          p2 = Scan.layout(@buf, pos + 1, stop)
          break if p2 < stop && ptr[p2] == RS
          raise SyntaxError.new("keyed unit in a positional record (mixed record)", pos)
        else
          break
        end
      end
      pos
    end

    # Does a record starting here begin with a (live or dead) keyed unit?
    private def keyed_start?(pos : Int32, stop : Int32) : Bool
      ptr = @buf.to_unsafe
      while pos < stop
        b = ptr[pos]
        return true if b == SOH
        return false unless b == BEL
        p2 = Scan.layout(@buf, pos + 1, stop)
        return false if p2 >= stop
        return true if ptr[p2] == SOH
        return false if ptr[p2] < 0x20_u8 && ptr[p2] != STX
        pos = Scan.layout(@buf, Scan.comment(@buf, pos, stop), stop)
      end
      false
    end

    # After SOH. Returns {key, value-or-empty, pos}.
    private def keyed_unit(pos : Int32, stop : Int32, heading : Bool) : {Bytes, Bytes, Int32}
      ptr = @buf.to_unsafe
      pos = layout(pos, stop)
      ks = pos
      pos = Scan.plain(@buf, pos, stop)
      key = C0.trim(@buf[ks...pos])
      raise SyntaxError.new("key without a value (no US)", pos) unless pos < stop && ptr[pos] == US
      vs = pos + 1
      pos = value(vs, stop, heading: heading)
      {key, C0.trim(@buf[vs...pos]), pos}
    end

    # One value (possibly empty) starting at pos. Returns position after it
    # (before the next code at this depth).
    private def value(pos : Int32, stop : Int32, heading : Bool = false) : Int32
      ptr = @buf.to_unsafe
      pos = layout(pos, stop)
      return pos if pos >= stop
      b = ptr[pos]
      if b >= 0x20_u8
        start = pos
        pos = Scan.plain(@buf, pos, stop)
        v = @buf[start...pos]
        i = 0
        while i < v.size
          raise SyntaxError.new("layout code inside a plain value", start + i) if v[i] < 0x20_u8
          i += 1
        end
        not_canonical("layout bytes") if C0.layout?(v[v.size - 1])
        after = trailing_notes(layout(pos, stop), stop)
        raise SyntaxError.new("two values in one unit", after) if after < stop && (ptr[after] == STX || ptr[after] == DLE || ptr[after] == ENQ || ptr[after] >= 0x20_u8)
        return after
      elsif b == STX
        start = pos
        pos = Scan.text(@buf, pos, stop)
        inside = @buf[(start + 1)...(pos - 1)]
        if @canonical
          not_canonical("empty text") if inside.size == 0
          not_canonical("gratuitous text") if inside.size > 0 && C0.plain?(C0.decode_text(inside))
        end
        after = trailing_notes(layout(pos, stop), stop)
        raise SyntaxError.new("two values in one unit", after) if after < stop && (ptr[after] >= 0x20_u8 || ptr[after] == STX || ptr[after] == DLE || ptr[after] == ENQ)
        return after
      elsif b == DLE
        pos = level(pos, stop)
        after = trailing_notes(layout(pos, stop), stop)
        raise SyntaxError.new("two values in one unit", after) if after < stop && (ptr[after] >= 0x20_u8 || ptr[after] == STX || ptr[after] == DLE || ptr[after] == ENQ)
        return after
      elsif b == ENQ
        raise SyntaxError.new("reference in a heading", pos) if heading
        pos = layout(pos + 1, stop)
        raise SyntaxError.new("reference without a name", pos) if pos >= stop || (ptr[pos] < 0x20_u8 && ptr[pos] != STX)
        if ptr[pos] == STX
          start = pos
          pos = Scan.text(@buf, pos, stop)
          inside = C0.decode_text(@buf[(start + 1)...(pos - 1)])
          segs = inside.size == 0 ? [] of Bytes : split_us(inside)
          raise SyntaxError.new("reference path with an empty segment", start) if segs.any? { |s| s.size == 0 }
          raise SyntaxError.new("reference path with more than three segments", start) if segs.size > 3
          not_canonical("group reference written as text") if segs.size == 1
        else
          pos = Scan.plain(@buf, pos, stop)
        end
        return trailing_notes(layout(pos, stop), stop)
      elsif b == BEL
        # a note or dead level in unit position: the unit is empty
        p2 = Scan.layout(@buf, pos + 1, stop)
        raise UnexpectedEndError.new("BEL at end of input", p2) if p2 >= stop
        if ptr[p2] == DLE
          not_canonical("dead element")
          pos = level(p2, stop)
        elsif p2 < stop && ptr[p2] < 0x20_u8 && ptr[p2] != STX
          return pos # a dead record-level element: handled by the caller
        else
          not_canonical("comment")
          pos = p2 < stop && ptr[p2] == STX ? Scan.text(@buf, p2, stop) : Scan.plain(@buf, p2, stop)
        end
        return layout(pos, stop)
      else
        return pos
      end
    end

    # Notes (BEL + content) after a value inside a unit; a BEL before a code
    # is left for the caller.
    private def trailing_notes(pos : Int32, stop : Int32) : Int32
      ptr = @buf.to_unsafe
      while pos < stop && ptr[pos] == BEL
        p2 = Scan.layout(@buf, pos + 1, stop)
        raise UnexpectedEndError.new("BEL at end of input", p2) if p2 >= stop
        break unless ptr[p2] >= 0x20_u8 || ptr[p2] == STX
        not_canonical("comment")
        pos = ptr[p2] == STX ? Scan.text(@buf, p2, stop) : Scan.plain(@buf, p2, stop)
        pos = layout(pos, stop)
      end
      pos
    end

    private def split_us(bytes : Bytes) : Array(Bytes)
      out = Array(Bytes).new
      s = 0
      i = 0
      while i < bytes.size
        if bytes[i] == US
          out << bytes[s...i]
          s = i + 1
        end
        i += 1
      end
      out << bytes[s...bytes.size]
      out
    end

    # DLE at pos: a nested level. Returns position after CAN.
    private def level(pos : Int32, stop : Int32) : Int32
      ptr = @buf.to_unsafe
      pos = layout(pos + 1, stop)
      raise UnexpectedEndError.new("level not closed", pos) if pos >= stop
      b = ptr[pos]
      return pos + 1 if b == CAN
      raise SyntaxError.new("DLE must be followed by a structural code", pos) unless b == FS || b == GS || b == RS || b == SOH || b == BEL
      pos = body(pos, stop, depth0: false)
      pos = layout(pos, stop)
      raise UnexpectedEndError.new("level not closed", pos) if pos >= stop
      raise SyntaxError.new("unexpected byte inside level", pos) unless ptr[pos] == CAN
      pos + 1
    end

    private def plain_name(pos : Int32, stop : Int32) : Int32
      ptr = @buf.to_unsafe
      pos = layout(pos, stop)
      raise SyntaxError.new("a name cannot be text", pos) if pos < stop && ptr[pos] == STX
      start = pos
      pos = Scan.plain(@buf, pos, stop)
      not_canonical("layout bytes") if pos > start && C0.layout?(ptr[pos - 1])
      pos
    end

    private def comment(pos : Int32, stop : Int32, allow_dead : Bool) : Int32
      not_canonical("comment")
      Scan.comment(@buf, pos, stop)
    end

    # ---- diff body -----------------------------------------------------
    private def diff_body(pos : Int32, stop : Int32) : Int32
      ptr = @buf.to_unsafe
      pos = layout(pos, stop)
      while pos < stop
        b = ptr[pos]
        if b == FS
          pos = plain_name(pos + 1, stop)
        elsif b == GS
          pos = pattern(pos + 1, stop)
        elsif b == RS
          pos = replace(pos + 1, stop)
        elsif b == BEL
          p2 = Scan.layout(@buf, pos + 1, stop)
          if p2 < stop && ptr[p2] == FS
            pos = plain_name(p2 + 1, stop)
          elsif p2 < stop && ptr[p2] == GS
            pos = pattern(p2 + 1, stop)
          elsif p2 < stop && ptr[p2] == RS
            pos = replace(p2 + 1, stop)
          else
            pos = notes(pos, stop)
          end
        elsif b == ETB
          not_canonical("commit")
          pos = Scan.plain(@buf, layout(pos + 1, stop), stop)
        elsif b == EOT || b == SYN || b == EM
          break
        else
          raise SyntaxError.new("unexpected byte in a diff body", pos)
        end
        pos = layout(pos, stop)
      end
      pos
    end

    private def dvalue(pos : Int32, stop : Int32) : Int32
      ptr = @buf.to_unsafe
      pos = layout(pos, stop)
      return pos if pos >= stop
      if ptr[pos] == STX
        pos = Scan.text(@buf, pos, stop)
      elsif ptr[pos] >= 0x20_u8
        pos = Scan.plain(@buf, pos, stop)
      end
      layout(pos, stop)
    end

    private def pattern(pos : Int32, stop : Int32) : Int32
      ptr = @buf.to_unsafe
      loop do
        pos = dvalue(pos, stop)
        if pos < stop && ptr[pos] == SUB
          pos = dvalue(pos + 1, stop)
        end
        pos = trailing_notes(pos, stop)
        break unless pos < stop && ptr[pos] == US
        pos += 1
      end
      pos
    end

    private def replace(pos : Int32, stop : Int32) : Int32
      ptr = @buf.to_unsafe
      start = Scan.layout(@buf, pos, stop)
      pos = dvalue(pos, stop)
      raise SyntaxError.new("replace-all with an empty old part", start) if C0.trim(@buf[start...pos]).size == 0
      raise SyntaxError.new("replace-all without SUB", pos) unless pos < stop && ptr[pos] == SUB
      dvalue(pos + 1, stop)
    end
  end

  def self.validate(buf : Bytes) : Nil
    Validator.validate(buf)
  end

  # Whether bytes are a canonical unit (DESIGN.md "Canonical Form").
  def self.canonical?(buf : Bytes) : Bool
    Validator.canonical?(buf)
  end
end
