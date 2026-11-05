module C0
  # Pretty form: Unicode Control Pictures (U+2400 block) for the codes,
  # line breaks and indentation as layout. `format` and `parse` are
  # inverses on well-formed input.
  module Pretty
    enum FormatMode
      Compact # one element per line, no padding
      Aligned # column-aligned units within table groups
      Spaced  # aligned, plus a space after the prefix and around ␟
    end

    class GlyphInDataError < C0::Error; end

    @[AlwaysInline]
    def self.glyph(byte : UInt8) : Char
      (0x2400 + byte).chr
    end

    def self.format(buf : Bytes, indent : String = "  ", mode : FormatMode = FormatMode::Compact) : String
      compact = String.build { |io| format_compact(buf, io, indent) }
      return compact if mode.compact?
      align(compact, mode)
    end

    def self.format(buf : Bytes, io : IO, indent : String = "  ", mode : FormatMode = FormatMode::Compact) : Nil
      if mode.compact?
        format_compact(buf, io, indent)
      else
        io << align(String.build { |cio| format_compact(buf, cio, indent) }, mode)
      end
    end

    # ---- formatting ----------------------------------------------------

    private def self.format_compact(buf : Bytes, io : IO, indent : String) : Nil
      pos = 0
      len = buf.size.to_i32
      ptr = buf.to_unsafe
      depth = 0        # nesting depth (levels)
      gdepth = 0       # group depth within the current level
      line_start = true
      stack = Array(Int32).new

      while pos < len
        byte = ptr[pos]
        if byte >= 0x20_u8 || C0.layout?(byte)
          # stray plain or layout at element level: layout is dropped
          if C0.layout?(byte)
            pos += 1
          else
            start = pos
            pos = Scan.plain(buf, pos, len)
            write_data(buf[start...pos], io)
            line_start = false
          end
          next
        end
        case byte
        when SYN
          io << '\n' unless line_start
          io << glyph(SYN)
          pos += 1
          pos = write_heading(buf, pos, len, io)
          io << '\n'
          line_start = true
          gdepth = 0
        when FS
          io << '\n' unless line_start
          write_indent(io, indent, depth)
          io << glyph(FS)
          pos = write_plain(buf, pos + 1, len, io)
          io << '\n'
          line_start = true
          gdepth = 1
        when GS
          run = 0
          while pos < len && ptr[pos] == GS
            run += 1
            pos += 1
          end
          io << '\n' unless line_start
          write_indent(io, indent, depth)
          run.times { io << glyph(GS) }
          pos = write_plain(buf, pos, len, io)
          io << '\n'
          line_start = true
          gdepth = 1
        when SOH, RS, BEL, ETB
          io << '\n' unless line_start
          write_indent(io, indent, depth + gdepth)
          pos, depth, line_start = write_element(buf, pos, len, io, indent, depth, gdepth, stack)
        when CAN
          depth -= 1 if depth > 0
          gdepth = stack.pop? || 0
          io << '\n' unless line_start
          write_indent(io, indent, depth + gdepth)
          io << glyph(CAN)
          pos += 1
          line_start = false
          # the rest of the enclosing record continues on this line
          pos = write_units(buf, pos, len, io, indent, depth, gdepth, stack) { |d, gd, ls| depth = d; gdepth = gd; line_start = ls }
          unless line_start
            io << '\n'
            line_start = true
          end
        when EOT
          io << '\n' unless line_start
          io << glyph(EOT)
          io << '\n'
          pos += 1
          line_start = true
        when EM
          io << '\n' unless line_start
          io << glyph(EM)
          tail = len - pos - 1
          io << " " << tail << " bytes" if tail > 0
          io << '\n'
          return
        when STX, DLE, ENQ, US, SUB
          # a unit-level code at element level (e.g. a diff pattern): write inline
          pos = write_units(buf, pos, len, io, indent, depth, gdepth, stack) { |d, gd, ls| depth = d; gdepth = gd; line_start = ls }
          io << '\n'
          line_start = true
        else
          raise UnassignedCodeError.new(byte, pos)
        end
      end
      io << '\n' unless line_start
    end

    # SOH / RS / BEL / ETB at element level: the element and its units on
    # one line (a level opener breaks the line).
    private def self.write_element(buf, pos, len, io, indent, depth, gdepth, stack) : {Int32, Int32, Bool}
      ptr = buf.to_unsafe
      byte = ptr[pos]
      line_start = false
      case byte
      when BEL
        io << glyph(BEL)
        pos = Scan.layout(buf, pos + 1, len)
        if pos < len && (ptr[pos] >= 0x20_u8 || ptr[pos] == STX)
          pos = write_units(buf, pos, len, io, indent, depth, gdepth, stack) { |d, gd, ls| depth = d; line_start = ls }
          io << '\n'
          return {pos, depth, true}
        end
        # dead element: fall through to render it on this line
        return {pos, depth, false} if pos >= len
        return write_element(buf, pos, len, io, indent, depth, gdepth, stack)
      when SOH
        io << glyph(SOH)
        pos = Scan.layout(buf, pos + 1, len)
        if pos < len && ptr[pos] == RS
          io << glyph(RS)
          pos += 1
        end
        pos = write_units(buf, pos, len, io, indent, depth, gdepth, stack) { |d, gd, ls| depth = d; line_start = ls }
      when RS
        io << glyph(RS)
        pos = write_units(buf, pos + 1, len, io, indent, depth, gdepth, stack) { |d, gd, ls| depth = d; line_start = ls }
      when ETB
        io << glyph(ETB)
        pos = write_plain(buf, pos + 1, len, io)
      end
      unless line_start
        io << '\n'
        line_start = true
      end
      {pos, depth, line_start}
    end

    # Units of a record/header/heading on the current line. Stops at a
    # record-level code. A level opener writes ␐, breaks the line and
    # yields the new depth; the caller resumes at the matching CAN.
    private def self.write_units(buf, pos, len, io, indent, depth, gdepth, stack, & : Int32, Int32, Bool ->) : Int32
      ptr = buf.to_unsafe
      while pos < len
        b = ptr[pos]
        if b >= 0x20_u8
          start = pos
          pos = Scan.plain(buf, pos, len)
          write_data(C0.trim(buf[start...pos]), io)
        elsif C0.layout?(b)
          pos += 1
        elsif b == US || b == ENQ || b == SUB
          io << glyph(b)
          pos += 1
        elsif b == SOH
          p2 = Scan.layout(buf, pos + 1, len)
          break if p2 < len && ptr[p2] == RS
          io << glyph(SOH)
          pos += 1
        elsif b == STX
          stop = Scan.text(buf, pos, len)
          write_text(buf[pos...stop], io)
          pos = stop
        elsif b == DLE
          io << glyph(DLE)
          io << '\n'
          stack << gdepth
          yield depth + 1, gdepth, true
          return pos + 1
        elsif b == BEL
          p2 = Scan.layout(buf, pos + 1, len)
          if p2 < len && (ptr[p2] >= 0x20_u8 || ptr[p2] == STX || ptr[p2] == DLE)
            io << glyph(BEL)
            pos = p2
          else
            break
          end
        elsif b == ETB
          io << glyph(ETB)
          pos = write_plain(buf, pos + 1, len, io)
        else
          break
        end
      end
      yield depth, gdepth, false
      pos
    end

    private def self.write_heading(buf, pos, len, io) : Int32
      ptr = buf.to_unsafe
      while pos < len
        b = ptr[pos]
        if b == SOH
          p2 = Scan.layout(buf, pos + 1, len)
          break if p2 < len && ptr[p2] == RS
          io << glyph(SOH)
          pos = write_plain(buf, p2, len, io)
          if pos < len && ptr[pos] == US
            io << glyph(US)
            pos += 1
            pos = Scan.layout(buf, pos, len)
            if pos < len && ptr[pos] == STX
              stop = Scan.text(buf, pos, len)
              write_text(buf[pos...stop], io)
              pos = stop
            elsif pos < len && ptr[pos] == DLE
              stop = Scan.level(buf, pos, len)
              # a nested heading value is written inline
              write_inline_level(buf[pos...stop], io)
              pos = stop
            else
              pos = write_plain(buf, pos, len, io)
            end
          end
        elsif b == BEL
          p2 = Scan.layout(buf, pos + 1, len)
          if p2 < len && (ptr[p2] >= 0x20_u8 || ptr[p2] == STX)
            io << glyph(BEL)
            pos = p2
            if ptr[pos] == STX
              stop = Scan.text(buf, pos, len)
              write_text(buf[pos...stop], io)
              pos = stop
            else
              pos = write_plain(buf, pos, len, io)
            end
          elsif p2 < len && ptr[p2] == SOH
            io << glyph(BEL)
            pos = p2
          else
            break
          end
        elsif C0.layout?(b)
          pos += 1
        else
          break
        end
      end
      pos
    end

    # A level written on one line (used for heading values).
    private def self.write_inline_level(raw : Bytes, io : IO) : Nil
      i = 0
      ptr = raw.to_unsafe
      while i < raw.size
        b = ptr[i]
        if b == STX
          stop = Scan.text(raw, i)
          write_text(raw[i...stop], io)
          i = stop
        elsif b >= 0x20_u8
          start = i
          i = Scan.plain(raw, i)
          write_data(C0.trim(raw[start...i]), io)
        elsif C0.layout?(b)
          i += 1
        else
          io << glyph(b)
          i += 1
        end
      end
    end

    private def self.write_plain(buf, pos, len, io) : Int32
      pos = Scan.layout(buf, pos, len)
      start = pos
      pos = Scan.plain(buf, pos, len)
      write_data(C0.trim(buf[start...pos]), io)
      pos
    end

    # A whole text (STX … ETX): glyphs for the brackets and for any control
    # byte inside; everything else as is.
    private def self.write_text(text : Bytes, io : IO) : Nil
      check_glyphs(text)
      io << glyph(STX)
      i = 1
      stop = text.size - 1
      ptr = text.to_unsafe
      while i < stop
        b = ptr[i]
        if b < 0x20_u8 && b != LF && b != CR && b != HT
          io << glyph(b)
        else
          io.write_byte(b)
        end
        i += 1
      end
      io << glyph(ETX)
    end

    private def self.write_data(data : Bytes, io : IO) : Nil
      check_glyphs(data)
      io.write(data)
    end

    # Pretty form cannot show a value that contains a Control Picture
    # character (U+2400–U+241F, UTF-8 E2 90 80–9F).
    private def self.check_glyphs(data : Bytes) : Nil
      i = 0
      while i + 2 < data.size
        if data[i] == 0xE2 && data[i + 1] == 0x90 && data[i + 2] >= 0x80 && data[i + 2] <= 0x9F
          raise GlyphInDataError.new("value contains a Control Picture character and cannot be shown in pretty form")
        end
        i += 1
      end
    end

    private def self.write_indent(io : IO, indent : String, depth : Int32) : Nil
      depth.times { io << indent }
    end

    # ---- parsing ---------------------------------------------------------

    # Pretty form → compact bytes. Glyphs become codes; outside text,
    # layout touching a code is dropped and interior spaces are kept;
    # inside text everything is kept.
    def self.parse(str : String) : Bytes
      io = IO::Memory.new
      chars = str.chars
      i = 0
      pending = IO::Memory.new # whitespace between data characters
      after_code = true
      while i < chars.size
      ch = chars[i]
        if ch.ord >= 0x2400 && ch.ord <= 0x241F
          code = (ch.ord - 0x2400).to_u8
          pending.clear
          io.write_byte(code)
          i += 1
          if code == STX
            i = parse_text(chars, i, io)
          elsif code == EM
            # the rest of the line is a summary, not data
            while i < chars.size && chars[i] != '\n'
              i += 1
            end
          end
          after_code = true
        elsif ch == '\n' || ch == '\r'
          pending.clear
          after_code = true
          i += 1
        elsif ch == ' ' || ch == '\t'
          pending << ch unless after_code
          i += 1
        else
          if pending.size > 0
            io.write(pending.to_slice)
            pending.clear
          end
          after_code = false
          ch.each_byte { |b| io.write_byte(b) }
          i += 1
        end
      end
      io.to_slice
    end

    # Inside text: everything verbatim until the ETX glyph; a DLE glyph
    # takes the next glyph with it.
    private def self.parse_text(chars : Array(Char), i : Int32, io : IO) : Int32
      while i < chars.size
        ch = chars[i]
        if ch.ord >= 0x2400 && ch.ord <= 0x241F
          code = (ch.ord - 0x2400).to_u8
          io.write_byte(code)
          i += 1
          if code == DLE && i < chars.size
            nx = chars[i]
            if nx.ord >= 0x2400 && nx.ord <= 0x241F
              io.write_byte((nx.ord - 0x2400).to_u8)
              i += 1
            end
          elsif code == ETX
            return i
          end
        else
          ch.each_byte { |b| io.write_byte(b) }
          i += 1
        end
      end
      i
    end

    # ---- alignment -------------------------------------------------------

    G_FS  = glyph(FS)
    G_GS  = glyph(GS)
    G_RS  = glyph(RS)
    G_SOH = glyph(SOH)
    G_US  = glyph(US)
    G_EOT = glyph(EOT)
    G_STX = glyph(STX)
    G_ETX = glyph(ETX)
    G_DLE = glyph(DLE)
    G_CAN = glyph(CAN)
    G_SYN = glyph(SYN)
    G_BEL = glyph(BEL)

    PREFIXES = Set{G_FS, G_GS, G_RS, G_SOH, G_US, G_SYN, G_BEL}

    # seps[i] is what stood between fields[i] and fields[i+1]: G_US, or ""
    # when the next field begins with its own SOH mark.
    private record TableLine, line_index : Int32, prefix : String, fields : Array(String), seps : Array(String)
    private record TableGroup, lines : Array(TableLine)

    # Reformat a pretty-form string with column alignment. Keyed records
    # (SOH units) are aligned on their US like two-column tables.
    def self.align(pretty : String, mode : FormatMode = FormatMode::Spaced) : String
      lines = pretty.split('\n')
      lines.pop if lines.last?.try(&.empty?)
      groups = find_table_groups(lines)
      spaced = mode.spaced?
      sp = spaced ? " " : ""

      table_line_indices = Set(Int32).new
      groups.each { |g| g.lines.each { |l| table_line_indices << l.line_index } }

      groups.each do |group|
        next if group.lines.empty?
        col_count = group.lines.map(&.fields.size).max
        max_widths = Array(Int32).new(col_count, 0)
        group.lines.each do |line|
          line.fields.each_with_index { |f, c| max_widths[c] = Math.max(max_widths[c], f.size) }
        end
        group.lines.each do |line|
          text = String.build do |io|
            io << line.prefix << sp
            line.fields.each_with_index do |field, col|
              if col < line.fields.size - 1
                io << field
                (max_widths[col] - field.size).times { io << ' ' }
                if line.seps[col] == G_US.to_s
                  io << sp << G_US << sp
                else
                  io << ' '
                end
              else
                io << field
              end
            end
          end
          lines[line.line_index] = text
        end
      end

      lines.each_with_index do |text, i|
        next if table_line_indices.includes?(i)
        next if text.strip.empty?
        ws_end = 0
        while ws_end < text.size && (text[ws_end] == ' ' || text[ws_end] == '\t')
          ws_end += 1
        end
        indent_str = text[0...ws_end]
        glyph_end = ws_end
        while glyph_end < text.size && PREFIXES.includes?(text[glyph_end])
          glyph_end += 1
        end
        next if glyph_end == ws_end
        next if glyph_end >= text.size
        glyphs = text[ws_end...glyph_end]
        rest = text[glyph_end..]
        lines[i] = spaced ? "#{indent_str}#{glyphs} #{rest.lstrip}" : "#{indent_str}#{glyphs}#{rest.lstrip}"
      end

      lines.join('\n') + '\n'
    end

    private def self.find_table_groups(lines : Array(String)) : Array(TableGroup)
      groups = Array(TableGroup).new
      current : Array(TableLine)? = nil
      lines.each_with_index do |text, i|
        trimmed = text.strip
        if trimmed.empty? || trimmed.starts_with?(G_GS) || trimmed.starts_with?(G_FS) || trimmed.starts_with?(G_EOT) || trimmed.starts_with?(G_SYN) || trimmed.starts_with?(G_CAN)
          if cur = current
            groups << TableGroup.new(cur) unless cur.empty?
          end
          current = nil
          next
        end
        if trimmed.starts_with?(G_SOH) || trimmed.starts_with?(G_RS)
          parsed = parse_table_line(i, text)
          if parsed.nil? || parsed.fields.size < 2
            if cur = current
              groups << TableGroup.new(cur) unless cur.empty?
            end
            current = nil
            next
          end
          current = Array(TableLine).new if current.nil?
          current.not_nil! << parsed
        else
          if cur = current
            groups << TableGroup.new(cur) unless cur.empty?
          end
          current = nil
        end
      end
      if cur = current
        groups << TableGroup.new(cur) unless cur.empty?
      end
      groups
    end

    # Split a ␞ or ␁␞ line into its units on ␟ (text is not split; a keyed
    # record splits on its ␁ marks too, so key and value align).
    private def self.parse_table_line(line_index : Int32, text : String) : TableLine?
      chars = text.chars
      i = 0
      while i < chars.size && (chars[i] == ' ' || chars[i] == '\t')
        i += 1
      end
      return nil unless i < chars.size
      prefix_start = i
      if chars[i] == G_SOH
        i += 1
        return nil unless i < chars.size && chars[i] == G_RS
        i += 1
      elsif chars[i] == G_RS
        i += 1
      else
        return nil
      end
      prefix = text[0...i]
      fields = Array(String).new
      seps = Array(String).new
      field = String::Builder.new
      in_text = false
      keyed = i < chars.size && chars[i] == G_SOH
      while i < chars.size
        ch = chars[i]
        if in_text
          field << ch
          in_text = false if ch == G_ETX
          if ch == G_DLE && i + 1 < chars.size
            field << chars[i + 1]
            i += 1
          end
        elsif ch == G_STX
          in_text = true
          field << ch
        elsif ch == G_DLE || ch == G_CAN
          return nil # nested levels are not aligned
        elsif ch == G_US
          fields << field.to_s.strip
          seps << G_US.to_s
          field = String::Builder.new
        elsif keyed && ch == G_SOH && i > prefix.size
          fields << field.to_s.strip
          seps << ""
          field = String::Builder.new
          field << ch
        else
          field << ch
        end
        i += 1
      end
      return nil if in_text # text continues on the next line
      fields << field.to_s.strip
      return nil if fields.size < 2
      TableLine.new(line_index, prefix, fields, seps)
    end
  end
end
