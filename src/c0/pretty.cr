module C0
  # Unicode Control Pictures (U+2400 block) for pretty-printing.
  # Each C0 code at position N maps to U+2400+N.
  module Pretty
    enum FormatMode
      Compact  # No padding between fields (default)
      Aligned  # Column-aligned fields within table groups
      Spaced   # Column-aligned + space after prefix + space around ␟
    end

    # Convert a C0 control byte to its Unicode Control Picture character.
    @[AlwaysInline]
    def self.glyph(byte : UInt8) : Char
      (0x2400 + byte).chr
    end

    # Format a compact C0DATA buffer as a human-readable Unicode string
    # with newlines and indentation.
    def self.format(buf : Bytes, indent : String = "  ", mode : FormatMode = FormatMode::Compact) : String
      compact = String.build do |io|
        format_compact(buf, io, indent)
      end
      return compact if mode.compact?
      align(compact, mode)
    end

    # Format to an IO.
    def self.format(buf : Bytes, io : IO, indent : String = "  ", mode : FormatMode = FormatMode::Compact) : Nil
      if mode.compact?
        format_compact(buf, io, indent)
      else
        compact = String.build do |cio|
          format_compact(buf, cio, indent)
        end
        io << align(compact, mode)
      end
    end

    private def self.format_compact(buf : Bytes, io : IO, indent : String = "  ") : Nil
      pos = 0
      len = buf.size
      ptr = buf.to_unsafe
      depth = 0
      line_start = true
      gs_run = 0

      while pos < len
        byte = ptr[pos]

        if byte < 0x20_u8
          case byte
          when FS
            depth = 0
            io << '\n' unless line_start
            io << glyph(byte)
            pos += 1
            depth = 1
            gs_run = 0
            write_data_until_control(buf, pos, io) { |new_pos| pos = new_pos }
            io << '\n'
            line_start = true
          when GS
            # Count consecutive GS for depth
            gs_run = 0
            while pos < len && ptr[pos] == GS
              gs_run += 1
              pos += 1
            end
            io << '\n' unless line_start
            write_indent(io, indent, depth)
            gs_run.times { io << glyph(GS) }
            write_data_until_control(buf, pos, io) { |new_pos| pos = new_pos }
            io << '\n'
            line_start = true
          when SOH
            write_indent(io, indent, depth + 1)
            io << glyph(byte)
            pos += 1
            # Write header fields on same line
            write_fields_line(buf, pos, io) { |new_pos| pos = new_pos }
            io << '\n'
            line_start = true
          when RS
            write_indent(io, indent, depth + 1)
            io << glyph(byte)
            pos += 1
            # Write record fields on same line
            write_fields_line(buf, pos, io) { |new_pos| pos = new_pos }
            io << '\n'
            line_start = true
          when STX
            io << glyph(byte)
            pos += 1
            depth += 1
            io << '\n'
            line_start = true
          when ETX
            depth -= 1 if depth > 0
            write_indent(io, indent, depth + 1)
            io << glyph(byte)
            pos += 1
            # Don't add newline here — let the next token handle it
          when EOT
            io << '\n' unless line_start
            io << glyph(byte)
            io << '\n'
            pos += 1
            line_start = true
          when ENQ
            io << glyph(byte)
            pos += 1
          when DLE
            io << glyph(byte)
            pos += 1
            if pos < len
              io << glyph(ptr[pos]) if ptr[pos] < 0x20_u8
              io.write_byte(ptr[pos]) if ptr[pos] >= 0x20_u8
              pos += 1
            end
          when SUB
            io << glyph(byte)
            pos += 1
          when US
            io << glyph(byte)
            pos += 1
          when ETB
            # Commit marker not attached to a record line (e.g. after a
            # group-name line). Indented on its own line with any payload.
            write_indent(io, indent, depth + 1) if line_start
            io << glyph(byte)
            pos += 1
            write_data_until_control(buf, pos, io) { |new_pos| pos = new_pos }
            io << '\n'
            line_start = true
          else
            # Unassigned — show glyph
            io << glyph(byte)
            pos += 1
          end
        else
          # Data byte
          io.write_byte(byte)
          pos += 1
          line_start = false
        end
      end
      io << '\n' unless line_start
    end

    # Parse pretty-form back to compact form.
    #
    # Rules:
    # - Unicode Control Pictures (U+2400-U+241F) → C0 bytes
    # - LF/CR are ignored (formatting only)
    # - Whitespace (space/tab) adjacent to control codes is trimmed
    # - Inside STX/ETX (␂...␃), everything is preserved verbatim
    #   (no trimming). This allows STX/ETX to serve as quoting for
    #   values with significant whitespace.
    def self.parse(str : String) : Bytes
      io = IO::Memory.new
      iter = str.each_char
      whitespace_buf = IO::Memory.new
      trim_after = true # trim leading whitespace at start of input

      while true
        c = iter.next
        break if c.is_a?(Iterator::Stop)
        char = c.as(Char)

        if char.ord >= 0x2400 && char.ord <= 0x241F
          code = (char.ord - 0x2400).to_u8
          # Discard buffered whitespace (trim before control code)
          whitespace_buf.clear

          if code == STX
            io.write_byte(code)
            # Inside STX/ETX: preserve everything verbatim
            parse_quoted(iter, io)
          else
            io.write_byte(code)
          end
          # Trim whitespace after control code too
          trim_after = true
        elsif char == '\n' || char == '\r'
          # Ignored — also discard buffered whitespace
          whitespace_buf.clear
          trim_after = true
        elsif char == ' ' || char == '\t'
          if trim_after
            # Skip whitespace immediately after a control code or newline
            next
          end
          # Buffer whitespace — only flush if followed by data
          whitespace_buf << char
        else
          trim_after = false
          # Data character: flush buffered whitespace first
          if whitespace_buf.size > 0
            io.write(whitespace_buf.to_slice)
            whitespace_buf.clear
          end
          char.each_byte { |b| io.write_byte(b) }
        end
      end

      io.to_slice
    end

    # Parse inside STX/ETX — preserve everything verbatim until
    # matching ETX glyph (␃). Handles nested STX/ETX.
    private def self.parse_quoted(iter : Iterator(Char), io : IO) : Nil
      depth = 1

      while true
        c = iter.next
        break if c.is_a?(Iterator::Stop)
        char = c.as(Char)

        if char.ord >= 0x2400 && char.ord <= 0x241F
          code = (char.ord - 0x2400).to_u8
          io.write_byte(code)

          if code == STX
            depth += 1
          elsif code == ETX
            depth -= 1
            break if depth == 0
          end
        else
          # Preserve everything — newlines, spaces, all of it
          char.each_byte { |b| io.write_byte(b) }
        end
      end
    end

    # Write data bytes from buf[pos] until the next control code.
    private def self.write_data_until_control(buf : Bytes, pos : Int32, io : IO, & : Int32 ->) : Nil
      ptr = buf.to_unsafe
      len = buf.size
      while pos < len && ptr[pos] >= 0x20_u8
        io.write_byte(ptr[pos])
        pos += 1
      end
      yield pos
    end

    # Write fields (data separated by US) on a single line until the next
    # structural control code (RS, GS, FS, EOT, ETX, SOH, STX).
    private def self.write_fields_line(buf : Bytes, pos : Int32, io : IO, & : Int32 ->) : Nil
      ptr = buf.to_unsafe
      len = buf.size
      while pos < len
        byte = ptr[pos]
        if byte == US
          io << glyph(US)
          pos += 1
        elsif byte == DLE
          io << glyph(DLE)
          pos += 1
          if pos < len
            if ptr[pos] < 0x20_u8
              io << glyph(ptr[pos])
            else
              io.write_byte(ptr[pos])
            end
            pos += 1
          end
        elsif byte == ENQ
          io << glyph(ENQ)
          pos += 1
        elsif byte == ETB
          # Commit marker stays on the record's line, with any payload
          io << glyph(ETB)
          pos += 1
          while pos < len && ptr[pos] >= 0x20_u8
            io.write_byte(ptr[pos])
            pos += 1
          end
        elsif byte == STX
          io << glyph(STX)
          pos += 1
          # Write until ETX on same line
          while pos < len
            b = ptr[pos]
            if b == ETX
              io << glyph(ETX)
              pos += 1
              break
            elsif b == US
              io << glyph(US)
              pos += 1
            elsif b < 0x20_u8
              io << glyph(b)
              pos += 1
            else
              io.write_byte(b)
              pos += 1
            end
          end
        elsif byte < 0x20_u8
          # Next structural code — stop
          break
        else
          io.write_byte(byte)
          pos += 1
        end
      end
      yield pos
    end

    private def self.write_indent(io : IO, indent : String, depth : Int32) : Nil
      depth.times { io << indent }
    end

    # --- Column alignment ---

    G_FS  = glyph(FS)
    G_GS  = glyph(GS)
    G_RS  = glyph(RS)
    G_SOH = glyph(SOH)
    G_US  = glyph(US)
    G_EOT = glyph(EOT)
    G_DLE = glyph(DLE)

    PREFIXES = Set{G_FS, G_GS, G_RS, G_SOH, G_US}

    private record TableLine, line_index : Int32, prefix : String, fields : Array(String)
    private record TableGroup, lines : Array(TableLine)

    # Reformat a pretty-form string with column alignment.
    #
    # Modes:
    # - `Aligned` — column alignment only
    # - `Spaced`  — column alignment + space after prefix + space around ␟
    def self.align(pretty : String, mode : FormatMode = FormatMode::Spaced) : String
      lines = pretty.split('\n')
      # Remove trailing empty line from split (format always ends with \n)
      lines.pop if lines.last?.try(&.empty?)

      groups = find_table_groups(lines)
      spaced = mode.spaced?
      sp = spaced ? " " : ""

      # Build set of line indices handled by table groups
      table_line_indices = Set(Int32).new
      groups.each do |group|
        group.lines.each { |line| table_line_indices << line.line_index }
      end

      # Format table groups with column alignment
      groups.each do |group|
        next if group.lines.empty?

        col_count = group.lines[0].fields.size
        max_widths = Array(Int32).new(col_count, 0)
        group.lines.each do |line|
          line.fields.each_with_index do |field, col|
            max_widths[col] = Math.max(max_widths[col], field.size)
          end
        end

        group.lines.each do |line|
          text = String.build do |io|
            io << line.prefix << sp
            line.fields.each_with_index do |field, col|
              if col < line.fields.size - 1
                io << field
                (max_widths[col] - field.size).times { io << ' ' }
                io << sp << G_US << sp
              else
                io << field
              end
            end
          end
          lines[line.line_index] = text
        end
      end

      # Format non-table lines: add/remove space after prefix glyphs
      lines.each_with_index do |text, i|
        next if table_line_indices.includes?(i)
        next if text.strip.empty?

        # Find indent
        ws_end = 0
        while ws_end < text.size && (text[ws_end] == ' ' || text[ws_end] == '\t')
          ws_end += 1
        end
        indent_str = text[0...ws_end]

        # Find prefix glyphs
        glyph_end = ws_end
        while glyph_end < text.size && PREFIXES.includes?(text[glyph_end])
          glyph_end += 1
        end
        # Include SOH after prefix glyphs
        if glyph_end > ws_end && glyph_end < text.size && text[glyph_end] == G_SOH
          glyph_end += 1
        end

        next if glyph_end == ws_end   # no prefix glyphs
        next if glyph_end >= text.size # no content after prefix

        glyphs = text[ws_end...glyph_end]
        rest = text[glyph_end..]

        lines[i] = if spaced
                     "#{indent_str}#{glyphs} #{rest.lstrip}"
                   else
                     "#{indent_str}#{glyphs}#{rest.lstrip}"
                   end
      end

      lines.join('\n') + '\n'
    end

    private def self.find_table_groups(lines : Array(String)) : Array(TableGroup)
      groups = Array(TableGroup).new
      current : Array(TableLine)? = nil
      expected_cols = -1

      lines.each_with_index do |text, i|
        trimmed = text.strip

        # Group boundaries: empty, FS, GS, EOT
        if trimmed.empty? || trimmed.starts_with?(G_GS) || trimmed.starts_with?(G_FS) || trimmed.starts_with?(G_EOT)
          if cur = current
            groups << TableGroup.new(cur) unless cur.empty?
          end
          current = nil
          expected_cols = -1
          next
        end

        if trimmed.starts_with?(G_SOH) || trimmed.starts_with?(G_RS)
          parsed = parse_table_line(i, text)
          if parsed.nil? || parsed.fields.size < 2
            if cur = current
              groups << TableGroup.new(cur) unless cur.empty?
            end
            current = nil
            expected_cols = -1
            next
          end

          col_count = parsed.fields.size
          if current.nil? || (expected_cols != -1 && col_count != expected_cols)
            if cur = current
              groups << TableGroup.new(cur) unless cur.empty?
            end
            current = Array(TableLine).new
            expected_cols = col_count
          end

          current.not_nil! << parsed
        else
          if cur = current
            groups << TableGroup.new(cur) unless cur.empty?
          end
          current = nil
          expected_cols = -1
        end
      end

      if cur = current
        groups << TableGroup.new(cur) unless cur.empty?
      end
      groups
    end

    private def self.parse_table_line(line_index : Int32, text : String) : TableLine?
      # Find the prefix glyph (SOH or RS)
      marker_pos = -1
      text.each_char_with_index do |ch, i|
        next if ch == ' ' || ch == '\t'
        if ch == G_SOH || ch == G_RS
          marker_pos = i
          break
        end
        return nil
      end
      return nil if marker_pos == -1

      prefix = text[0..marker_pos]
      rest = text[(marker_pos + 1)..]

      # Split on US glyph, respecting DLE escapes
      fields = Array(String).new
      field = String::Builder.new
      i = 0
      chars = rest.chars
      while i < chars.size
        if chars[i] == G_DLE && i + 1 < chars.size
          field << chars[i] << chars[i + 1]
          i += 2
        elsif chars[i] == G_US
          fields << field.to_s.strip
          field = String::Builder.new
          i += 1
        else
          field << chars[i]
          i += 1
        end
      end
      fields << field.to_s.strip

      return nil if fields.size < 2

      TableLine.new(line_index, prefix, fields)
    end
  end
end
