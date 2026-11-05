module C0
  # Writes C0DATA in canonical compact form.
  #
  #   buf = C0::Builder.build do |b|
  #     b.syn(shape: "tabular")
  #     b.group("users", ["name", "amount"]) do
  #       b.record("Alice", "1502.30")
  #       b.record("Bob", "340.00")
  #     end
  #     b.eot
  #   end
  #
  # Values are written in their one spelling: plain when they can be, text
  # otherwise. Keyed records (`map`) are sorted. Nested levels (`level`,
  # `list`, `map` as a unit) open with DLE and close with CAN.
  class Builder
    @io : IO::Memory
    @in_record : Bool
    @units : Int32
    @stack : Array({Bool, Int32})

    def initialize
      @io = IO::Memory.new
      @in_record = false
      @units = 0
      @stack = Array({Bool, Int32}).new
    end

    def self.build(& : Builder ->) : Bytes
      b = new
      yield b
      b.to_slice
    end

    def to_slice : Bytes
      @io.to_slice
    end

    def to_s : String
      String.new(to_slice)
    end

    # ---- documents -------------------------------------------------------

    # SYN and a heading. Keys are sorted; values written as values; a
    # Builder block value is written as a nested level.
    def syn(pairs : Hash(String, String) = {} of String => String) : Nil
      end_record
      @io.write_byte(SYN)
      pairs.keys.sort!.each do |k|
        @io.write_byte(SOH)
        C0.write_name(@io, k.to_slice)
        @io.write_byte(US)
        C0.write_value(@io, pairs[k])
      end
    end

    def syn(**pairs) : Nil
      h = {} of String => String
      pairs.each { |k, v| h[k.to_s] = v.to_s }
      syn(h)
    end

    # A heading key whose value is a nested level (e.g. the blob table).
    def heading_level(key : String, & : ->) : Nil
      end_record
      @io.write_byte(SOH)
      C0.write_name(@io, key.to_slice)
      @io.write_byte(US)
      open_level { yield }
    end

    def eot : Nil
      end_record
      @io.write_byte(EOT)
    end

    def etb(payload : String? = nil) : Nil
      end_record
      @io.write_byte(ETB)
      if payload
        C0.write_name(@io, payload.to_slice)
      end
    end

    # EM and the raw tail. Nothing may follow.
    def em(tail : Bytes) : Nil
      end_record
      @io.write_byte(EM)
      @io.write(tail)
    end

    # ---- structure -------------------------------------------------------

    def file(name : String, & : ->) : Nil
      file(name)
      yield
    end

    def file(name : String) : Nil
      end_record
      @io.write_byte(FS)
      C0.write_name(@io, name.to_slice)
    end

    def group(name : String, headers : Indexable(String)? = nil, depth : Int32 = 1, & : ->) : Nil
      group(name, headers, depth)
      yield
    end

    def group(name : String, headers : Indexable(String)? = nil, depth : Int32 = 1) : Nil
      end_record
      depth.times { @io.write_byte(GS) }
      C0.write_name(@io, name.to_slice)
      header(headers) if headers
    end

    # A header row: SOH RS names.
    def header(names : Indexable(String)) : Nil
      end_record
      @io.write_byte(SOH)
      @io.write_byte(RS)
      names.each_with_index do |n, i|
        @io.write_byte(US) if i > 0
        C0.write_name(@io, n.to_slice)
      end
    end

    def header(*names : String) : Nil
      header(names)
    end

    # Document mode: a section at depth.
    def section(name : String, depth : Int32 = 1, & : ->) : Nil
      group(name, nil, depth)
      yield
    end

    def section(name : String, depth : Int32 = 1) : Nil
      group(name, nil, depth)
    end

    # ---- records -----------------------------------------------------------

    # A positional record.
    def record(*fields : String | Bytes) : Nil
      record(fields)
    end

    def record(fields : Indexable(String | Bytes) | Indexable(String) | Indexable(Bytes)) : Nil
      start_record
      fields.each { |f| field(f) }
    end

    # Begin a record and leave it open for `field` / `level` / `list` calls.
    def record : Nil
      start_record
    end

    # Document mode: a paragraph.
    def block(text : String) : Nil
      record(text)
    end

    # Document mode: a list item (a unit of the open block).
    def item(text : String) : Nil
      field(text)
    end

    # Append a unit to the open record (opens one if none is open).
    def field(value : String | Bytes) : Nil
      next_unit
      C0.write_value(@io, value.is_a?(String) ? value.to_slice : value)
    end

    # A keyed record: a map, keys sorted. Values may be strings or, for a
    # nested level, a Proc taking no arguments that writes it.
    def map(pairs : Hash(String, String)) : Nil
      start_record
      pairs.keys.sort!.each do |k|
        @io.write_byte(SOH)
        C0.write_name(@io, k.to_slice)
        @io.write_byte(US)
        C0.write_value(@io, pairs[k])
      end
      @units += pairs.size
    end

    # One keyed unit on the open record (caller keeps keys sorted).
    def key(name : String, value : String | Bytes) : Nil
      start_record unless @in_record
      @io.write_byte(SOH)
      C0.write_name(@io, name.to_slice)
      @io.write_byte(US)
      C0.write_value(@io, value.is_a?(String) ? value.to_slice : value)
      @units += 1
    end

    # One keyed unit whose value is a nested level.
    def key(name : String, & : ->) : Nil
      start_record unless @in_record
      @io.write_byte(SOH)
      C0.write_name(@io, name.to_slice)
      @io.write_byte(US)
      @units += 1
      open_level { yield }
    end

    # ---- values that are not plain -------------------------------------

    # A nested level as the next unit. Inside the block the builder is at
    # the top of a fresh body.
    def level(& : ->) : Nil
      next_unit
      open_level { yield }
    end

    # A flat list as the next unit: a level holding one record.
    def list(items : Indexable(String)) : Nil
      next_unit
      @io.write_byte(DLE)
      if items.empty?
        @io.write_byte(CAN)
      else
        @io.write_byte(RS)
        items.each_with_index do |it, i|
          @io.write_byte(US) if i > 0
          C0.write_value(@io, it)
        end
        @io.write_byte(CAN)
      end
    end

    # Compatibility name.
    def list_field(items : Indexable(String)) : Nil
      list(items)
    end

    # A group reference as the next unit.
    def ref(name : String) : Nil
      next_unit
      @io.write_byte(ENQ)
      C0.write_name(@io, name.to_slice)
    end

    # A path reference as the next unit.
    def ref(*path : String) : Nil
      next_unit
      @io.write_byte(ENQ)
      if path.size == 1
        C0.write_name(@io, path[0].to_slice)
      else
        @io.write_byte(STX)
        path.each_with_index do |seg, i|
          @io.write_byte(US) if i > 0
          raise Error.new("reference segment is not a name") unless C0.name?(seg.to_slice) && !seg.empty?
          @io.write(seg.to_slice)
        end
        @io.write_byte(ETX)
      end
    end

    # ---- comments ----------------------------------------------------------

    # A note at the current position (record level, or as an empty unit).
    def note(text : String) : Nil
      @io.write_byte(BEL)
      if C0.plain?(text.to_slice)
        @io.write(text.to_slice)
      else
        C0.write_value(@io, text)
      end
    end

    # ---- internals ---------------------------------------------------------

    private def start_record : Nil
      @io.write_byte(RS)
      @in_record = true
      @units = 0
    end

    private def end_record : Nil
      @in_record = false
      @units = 0
    end

    private def next_unit : Nil
      start_record unless @in_record
      @io.write_byte(US) if @units > 0
      @units += 1
    end

    private def open_level(& : ->) : Nil
      @stack << {@in_record, @units}
      @in_record = false
      @units = 0
      @io.write_byte(DLE)
      yield
      @io.write_byte(CAN)
      st = @stack.pop
      @in_record = st[0]
      @units = st[1]
    end
  end
end
