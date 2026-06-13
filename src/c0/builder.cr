module C0
  # Builds C0DATA documents in compact form.
  #
  # Example:
  #   buf = C0::Builder.build do |b|
  #     b.file("mydb") do
  #       b.group("users", headers: ["name", "amount", "type"]) do
  #         b.record("Alice", "1502.30", "DEPOSIT")
  #         b.record("Bob", "340.00", "WITHDRAWAL")
  #       end
  #     end
  #   end
  class Builder
    @io : IO::Memory

    def initialize
      @io = IO::Memory.new
    end

    def self.build(& : Builder ->) : Bytes
      b = new
      yield b
      b.to_slice
    end

    # Write a file/database scope.
    def file(name : String, & : ->) : Nil
      @io.write_byte(FS)
      write_name(name)
      yield
    end

    # Write a file/database scope (no block).
    def file(name : String) : Nil
      @io.write_byte(FS)
      write_name(name)
    end

    # Write a group/table scope with optional headers.
    def group(name : String, headers : Indexable(String)? = nil, & : ->) : Nil
      @io.write_byte(GS)
      write_name(name)
      if h = headers
        @io.write_byte(SOH)
        h.each_with_index do |field, i|
          @io.write_byte(US) if i > 0
          write_name(field)
        end
      end
      yield
    end

    # Write a group/table scope (no block).
    def group(name : String, headers : Indexable(String)? = nil) : Nil
      @io.write_byte(GS)
      write_name(name)
      if h = headers
        @io.write_byte(SOH)
        h.each_with_index do |field, i|
          @io.write_byte(US) if i > 0
          write_name(field)
        end
      end
    end

    # Write a standalone SOH header (e.g. for stream mode, where the
    # header is appended and committed separately from the group).
    def header(names : Indexable(String)) : Nil
      @io.write_byte(SOH)
      names.each_with_index do |field, i|
        @io.write_byte(US) if i > 0
        write_name(field)
      end
    end

    # Write a record with positional fields.
    def record(*fields : String) : Nil
      @io.write_byte(RS)
      fields.each_with_index do |field, i|
        @io.write_byte(US) if i > 0
        write_escaped(field)
      end
    end

    # Write a record from an array of fields.
    def record(fields : Indexable(String)) : Nil
      @io.write_byte(RS)
      fields.each_with_index do |field, i|
        @io.write_byte(US) if i > 0
        write_escaped(field)
      end
    end

    # Write an EOT marker.
    def eot : Nil
      @io.write_byte(EOT)
    end

    # Write an ETB commit marker (stream mode), with an optional
    # integrity payload. The payload may not contain control bytes —
    # it is terminated by the next control code on read.
    def etb(payload : String? = nil) : Nil
      @io.write_byte(ETB)
      if p = payload
        p.each_byte do |byte|
          raise ArgumentError.new("ETB payload may not contain control bytes") if byte < 0x20_u8
          @io.write_byte(byte)
        end
      end
    end

    # Write a nested sub-structure.
    def nested(& : ->) : Nil
      @io.write_byte(STX)
      yield
      @io.write_byte(ETX)
    end

    # Write a reference to a named group.
    def ref(name : String) : Nil
      @io.write_byte(ENQ)
      @io << name
    end

    # Write a path reference (group, record id, optional field).
    def ref(*path : String) : Nil
      @io.write_byte(ENQ)
      @io.write_byte(STX)
      path.each_with_index do |segment, i|
        @io.write_byte(US) if i > 0
        @io << segment
      end
      @io.write_byte(ETX)
    end

    # Write a raw field value (for use within records when building
    # fields individually).
    def field(value : String) : Nil
      @io.write_byte(US)
      write_escaped(value)
    end

    # Write GS×N for document-mode depth.
    def section(name : String, depth : Int32 = 1, & : ->) : Nil
      depth.times { @io.write_byte(GS) }
      write_name(name)
      yield
    end

    # Write GS×N for document-mode depth (no block).
    def section(name : String, depth : Int32 = 1) : Nil
      depth.times { @io.write_byte(GS) }
      write_name(name)
    end

    # Write a content block (RS + text) for document mode.
    def block(text : String) : Nil
      @io.write_byte(RS)
      write_escaped(text)
    end

    # Write a list item (US + text) for document mode.
    def item(text : String) : Nil
      @io.write_byte(US)
      write_escaped(text)
    end

    def to_slice : Bytes
      @io.to_slice
    end

    # Writes a name (label or header). Names are identifiers, not
    # values — control bytes are illegal in them (see DESIGN.md
    # "Canonical Form").
    private def write_name(str : String) : Nil
      str.each_byte do |byte|
        if byte < 0x20_u8
          raise ArgumentError.new("Names may not contain control bytes (got 0x#{byte.to_s(16).rjust(2, '0')})")
        end
        @io.write_byte(byte)
      end
    end

    # Writes a string, DLE-escaping any control codes.
    private def write_escaped(str : String) : Nil
      str.each_byte do |byte|
        if byte < 0x20_u8
          @io.write_byte(DLE)
        end
        @io.write_byte(byte)
      end
    end
  end
end
