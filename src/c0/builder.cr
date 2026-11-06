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
  # Two layers. The primitives are one method per code (`fs`, `gs`, `rs`,
  # `us`, `sub`, `soh`, `dle`, `can`, `bel`, `enq`, `syn`, `eot`, `etb`, `em`); each
  # writes its code and, when given, what grammatically follows it, so a chain
  # reads like the bytes:
  #
  #   b.rs("Alice").us("1502.30")                        # ␞Alice␟1502.30
  #   b.rs.soh("host").us("localhost").soh("port").us("5432")
  #   b.bel.gs("old")                                    # a dead group
  #
  # The composed methods (`file`, `group`, `header`, `record`, `field`, `map`,
  # `key`, `level`, `list`, `ref`, `note`) are built on the primitives and
  # cannot write ill-formed output. The primitives write what you spell;
  # well-formedness is then yours to keep. Both layers share the record state,
  # so they mix.
  #
  # Values are written in their one spelling: plain when they can be, text
  # otherwise. Keyed records keep the order given. Nested levels open with DLE
  # and close with CAN.
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

    # ---- primitives: one method per code ---------------------------------

    # FS and a file name.
    def fs(name : String) : self
      end_record
      @io.write_byte(FS)
      C0.write_name(@io, name.to_slice)
      self
    end

    # GS and, when given, a group name. `gs.gs("sub")` is a group at depth 2.
    def gs(name : String? = nil) : self
      end_record
      @io.write_byte(GS)
      C0.write_name(@io, name.to_slice) if name
      self
    end

    # RS and, when given, the record's first value.
    def rs(value : String | Bytes | Nil = nil) : self
      @io.write_byte(RS)
      @in_record = true
      @units = 0
      first_value(value) if value
      self
    end

    # US and, when given, the value that follows it.
    def us(value : String | Bytes | Nil = nil) : self
      @io.write_byte(US)
      write_value(value) if value
      @units += 1
      self
    end

    # SUB and, when given, the new side of a substitution. C0-DIFF only:
    # `rs("old").sub("new")` is a replace-all; in a data body SUB is an error.
    def sub(value : String | Bytes | Nil = nil) : self
      @io.write_byte(SUB)
      write_value(value) if value
      self
    end

    # SOH and, when given, a key. Bare before `rs` it opens a header row.
    def soh(name : String? = nil) : self
      @io.write_byte(SOH)
      C0.write_name(@io, name.to_slice) if name
      self
    end

    # DLE: open a nested level. Inside, the builder is at the top of a fresh body.
    def dle : self
      @stack << {@in_record, @units}
      @in_record = false
      @units = 0
      @io.write_byte(DLE)
      self
    end

    # CAN: close the innermost level.
    def can : self
      raise Error.new("CAN with no open level") if @stack.empty?
      @io.write_byte(CAN)
      st = @stack.pop
      @in_record = st[0]
      @units = st[1]
      self
    end

    # BEL and, when given, a note. Bare, it marks the element that follows dead.
    def bel(text : String? = nil) : self
      if text
        raise ArgumentError.new("a note needs content: bare BEL marks the next element dead") if text.empty?
        @io.write_byte(BEL)
        write_value(text)
      else
        @io.write_byte(BEL)
      end
      self
    end

    # ENQ and a reference: a group name, or a path of two or three names.
    def enq(*path : String) : self
      raise Error.new("a reference path has one to three segments") unless 1 <= path.size <= 3
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
      self
    end

    # SYN: start a document. Heading pairs follow as `soh(key).us(value)`.
    def syn : self
      end_record
      @io.write_byte(SYN)
      self
    end

    # EOT: end a document.
    def eot : self
      end_record
      @io.write_byte(EOT)
      self
    end

    # ETB and, when given, a commit payload.
    def etb(payload : String? = nil) : self
      end_record
      @io.write_byte(ETB)
      C0.write_name(@io, payload.to_slice) if payload
      self
    end

    # EM and the raw tail. Nothing may follow.
    def em(tail : Bytes) : self
      end_record
      @io.write_byte(EM)
      @io.write(tail)
      self
    end

    # ---- documents -------------------------------------------------------

    # SYN and a heading. Keys in the order given.
    def syn(pairs : Hash(String, String)) : self
      syn
      pairs.each { |k, v| soh(k).us(v) }
      self
    end

    def syn(**pairs) : self
      syn
      pairs.each { |k, v| soh(k.to_s).us(v.to_s) }
      self
    end

    # A heading key whose value is a nested level (e.g. the blob table).
    def heading_level(key : String, & : ->) : self
      end_record
      soh(key).us.dle
      yield
      can
    end

    # ---- structure -------------------------------------------------------

    def file(name : String, & : ->) : self
      fs(name)
      yield
      self
    end

    def file(name : String) : self
      fs(name)
    end

    def group(name : String, headers : Indexable(String)? = nil, depth : Int32 = 1, & : ->) : self
      group(name, headers, depth)
      yield
      self
    end

    def group(name : String, headers : Indexable(String)? = nil, depth : Int32 = 1) : self
      (depth - 1).times { gs }
      gs(name)
      header(headers) if headers
      self
    end

    # A header row: SOH RS names.
    def header(names : Indexable(String)) : self
      names.each { |n| C0.write_name(IO::Memory.new, n.to_slice) }
      end_record
      soh.rs
      names.each_with_index do |n, i|
        i == 0 ? first_value(n) : us(n)
      end
      end_record
      self
    end

    def header(*names : String) : self
      header(names)
    end

    # Document mode: a section at depth.
    def section(name : String, depth : Int32 = 1, & : ->) : self
      group(name, nil, depth)
      yield
      self
    end

    def section(name : String, depth : Int32 = 1) : self
      group(name, nil, depth)
    end

    # ---- records -----------------------------------------------------------

    # A positional record.
    def record(*fields : String | Bytes) : self
      record(fields)
    end

    def record(fields : Indexable(String | Bytes) | Indexable(String) | Indexable(Bytes)) : self
      rs
      fields.each { |f| field(f) }
      self
    end

    # Begin a record and leave it open for `field` / `level` / `list` calls.
    def record : self
      rs
    end

    # Document mode: a paragraph.
    def block(text : String) : self
      record(text)
    end

    # Document mode: a list item (a unit of the open block).
    def item(text : String) : self
      field(text)
    end

    # Append a unit to the open record (opens one if none is open).
    def field(value : String | Bytes) : self
      if !@in_record
        rs(value)
      elsif @units == 0
        first_value(value)
        self
      else
        us(value)
      end
    end

    # A keyed record: a map, entries in the order given.
    def map(pairs : Hash(String, String)) : self
      rs
      pairs.each { |k, v| soh(k).us(v) }
      self
    end

    # One keyed unit on the open record (order is the caller's).
    def key(name : String, value : String | Bytes) : self
      rs unless @in_record
      soh(name).us(value)
    end

    # One keyed unit whose value is a nested level.
    def key(name : String, & : ->) : self
      rs unless @in_record
      soh(name).us.dle
      yield
      can
    end

    # ---- values that are not plain -------------------------------------

    # A nested level as the next unit. Inside the block the builder is at
    # the top of a fresh body.
    def level(& : ->) : self
      next_unit
      dle
      yield
      can
    end

    # A flat list as the next unit: a level holding one record.
    def list(items : Indexable(String)) : self
      next_unit
      dle
      unless items.empty?
        rs
        items.each { |it| field(it) }
      end
      can
    end

    # Compatibility name.
    def list_field(items : Indexable(String)) : self
      list(items)
    end

    # A reference as the next unit: a group name, or a path of names.
    def ref(*path : String) : self
      next_unit
      enq(*path)
    end

    # ---- comments ----------------------------------------------------------

    # A note at the current position. Content is required: a bare BEL is a
    # dead marker, written with `bel`.
    def note(text : String) : self
      raise ArgumentError.new("a note needs content: bare BEL marks the next element dead") if text.empty?
      bel(text)
    end

    # ---- internals ---------------------------------------------------------

    private def end_record : Nil
      @in_record = false
      @units = 0
    end

    # Position for the next unit of the open record (opening one if needed):
    # US between units, nothing before the first.
    private def next_unit : Nil
      if !@in_record
        rs
      elsif @units > 0
        @io.write_byte(US)
      end
      @units += 1
    end

    # The first value of a record, straight after RS.
    private def first_value(value : String | Bytes) : Nil
      write_value(value)
      @units = 1
    end

    private def write_value(value : String | Bytes) : Nil
      C0.write_value(@io, value.is_a?(String) ? value.to_slice : value)
    end
  end
end
