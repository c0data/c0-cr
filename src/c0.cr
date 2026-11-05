module C0
  VERSION = "1.0.0-dev"

  # Assigned C0 control codes (DESIGN.md "Assigned Control Codes")
  SOH = 0x01_u8 # Heading: a key for the value after it, or SOH RS a header row
  STX = 0x02_u8 # Start of text (literal value)
  ETX = 0x03_u8 # End of text
  EOT = 0x04_u8 # End of document
  ENQ = 0x05_u8 # Reference
  BEL = 0x07_u8 # Comment: a note, or marks the next element dead
  DLE = 0x10_u8 # Recurse: opens a nested level (outside text); escape (inside text)
  SYN = 0x16_u8 # Start of document, then the heading
  ETB = 0x17_u8 # Commit marker (stream mode)
  CAN = 0x18_u8 # Close a nested level
  EM  = 0x19_u8 # End of medium: raw blob follows
  SUB = 0x1a_u8 # Substitution (C0-DIFF)
  FS  = 0x1c_u8 # File separator
  GS  = 0x1d_u8 # Group separator
  RS  = 0x1e_u8 # Record separator
  US  = 0x1f_u8 # Unit separator

  # Layout codes outside text
  HT = 0x09_u8
  LF = 0x0a_u8
  CR = 0x0d_u8
  SP = 0x20_u8

  # Assigned structural/framing codes, for fast lookup
  ASSIGNED = StaticArray[
    false, true,  true,  true,  true,  true,  false, true,  # 0x00-0x07
    false, false, false, false, false, false, false, false, # 0x08-0x0F
    true,  false, false, false, false, false, true,  true,  # 0x10-0x17
    true,  true,  true,  false, true,  true,  true,  true,  # 0x18-0x1F
  ]

  # The seven codes that take a DLE inside text
  TEXT_ESCAPED = StaticArray[
    false, false, true,  true,  true,  false, false, false, # STX ETX EOT
    false, false, false, false, false, false, false, false,
    true,  false, false, false, false, false, true,  true,  # DLE SYN ETB
    false, true,  false, false, false, false, false, false, # EM
  ]

  class Error < Exception; end

  class SyntaxError < Error
    getter position : Int32

    def initialize(message : String, @position : Int32)
      super("#{message} at byte #{@position}")
    end
  end

  class UnassignedCodeError < SyntaxError
    getter byte : UInt8

    def initialize(@byte, position)
      super("Unassigned control code 0x#{@byte.to_s(16).rjust(2, '0')}", position)
    end
  end

  class UnexpectedEndError < SyntaxError
    def initialize(what : String, position : Int32)
      super("Unexpected end of input: #{what}", position)
    end
  end

  class KeyError < Error; end

  @[AlwaysInline]
  def self.layout?(byte : UInt8) : Bool
    byte == SP || byte == HT || byte == LF || byte == CR
  end

  @[AlwaysInline]
  def self.control?(byte : UInt8) : Bool
    byte < 0x20_u8
  end

  # ---------------------------------------------------------------------
  # Scanning primitives. All take a buffer and a position and return the
  # position after the construct. They raise on malformed input.
  # ---------------------------------------------------------------------
  module Scan
    extend self

    # Skip layout bytes.
    @[AlwaysInline]
    def layout(buf : Bytes, pos : Int32, stop : Int32 = buf.size) : Int32
      ptr = buf.to_unsafe
      while pos < stop && C0.layout?(ptr[pos])
        pos += 1
      end
      pos
    end

    # Skip a text (STX … ETX) starting at the STX at `pos`. Returns the
    # position after the ETX. Raises on an unclosed text, a bad escape,
    # a nested STX, or framing inside the text.
    def text(buf : Bytes, pos : Int32, stop : Int32 = buf.size) : Int32
      ptr = buf.to_unsafe
      start = pos
      pos += 1 # STX
      while pos < stop
        byte = ptr[pos]
        if byte == DLE
          pos += 1
          raise UnexpectedEndError.new("DLE at end of text", pos) if pos >= stop
          raise SyntaxError.new("DLE before a byte that is not one of the seven", pos) unless ptr[pos] < 0x20_u8 && TEXT_ESCAPED[ptr[pos]]
          pos += 1
        elsif byte == ETX
          return pos + 1
        elsif byte == STX
          raise SyntaxError.new("STX inside text (text does not nest)", pos)
        elsif byte == ETB || byte == EOT || byte == SYN || byte == EM
          raise SyntaxError.new("framing inside open text", pos)
        else
          pos += 1
        end
      end
      raise UnexpectedEndError.new("text opened at #{start} is not closed", pos)
    end

    # Skip a nested level starting at the DLE at `pos`. Returns the
    # position after the matching CAN.
    def level(buf : Bytes, pos : Int32, stop : Int32 = buf.size) : Int32
      ptr = buf.to_unsafe
      start = pos
      pos += 1 # DLE
      depth = 1
      while pos < stop
        byte = ptr[pos]
        if byte >= 0x20_u8
          pos += 1
        elsif byte == STX
          pos = text(buf, pos, stop)
        elsif byte == DLE
          depth += 1
          pos += 1
        elsif byte == CAN
          depth -= 1
          pos += 1
          return pos if depth == 0
        elsif byte == ETB || byte == EOT || byte == SYN || byte == EM
          raise SyntaxError.new("framing inside open level", pos)
        else
          pos += 1
        end
      end
      raise UnexpectedEndError.new("level opened at #{start} is not closed", pos)
    end

    # Skip a plain run of bytes >= 0x20 (a label, key, payload or plain
    # value with its layout). Returns the position of the next control
    # code or `stop`.
    @[AlwaysInline]
    def plain(buf : Bytes, pos : Int32, stop : Int32 = buf.size) : Int32
      ptr = buf.to_unsafe
      while pos < stop && ptr[pos] >= 0x20_u8
        pos += 1
      end
      pos
    end

    # From `pos` (just after a US, RS or key's US), find the end of one
    # unit's value: the next control code at this depth other than the
    # ones that belong to the value (STX…ETX, DLE…CAN, ENQ, BEL note).
    # Layout at the edges is included in the returned range.
    def unit(buf : Bytes, pos : Int32, stop : Int32 = buf.size) : Int32
      ptr = buf.to_unsafe
      while pos < stop
        byte = ptr[pos]
        if byte >= 0x20_u8
          pos += 1
        elsif C0.layout?(byte)
          pos += 1
        elsif byte == STX
          pos = text(buf, pos, stop)
        elsif byte == DLE
          pos = level(buf, pos, stop)
        elsif byte == ENQ
          pos += 1
        elsif byte == BEL
          # a note or a dead level stays inside the unit; a dead
          # record-level element (BEL RS / SOH / GS / FS) ends it
          p2 = layout(buf, pos + 1, stop)
          if p2 < stop && ptr[p2] < 0x20_u8 && ptr[p2] != STX && ptr[p2] != DLE
            return pos
          end
          pos = comment(buf, pos, stop)
        else
          return pos
        end
      end
      pos
    end

    # Skip a comment starting at the BEL at `pos`: a note (text or plain
    # to the next code) or a dead element (the next code's whole element).
    # Returns the position after it.
    def comment(buf : Bytes, pos : Int32, stop : Int32 = buf.size) : Int32
      ptr = buf.to_unsafe
      pos += 1 # BEL
      pos = layout(buf, pos, stop)
      return pos if pos >= stop
      byte = ptr[pos]
      if byte >= 0x20_u8
        pos = plain(buf, pos, stop)
        pos
      elsif byte == STX
        text(buf, pos, stop)
      elsif byte == DLE
        level(buf, pos, stop)
      elsif byte == RS
        record_end(buf, pos + 1, stop)
      elsif byte == SOH
        # header row or keyed unit
        p2 = layout(buf, pos + 1, stop)
        if p2 < stop && ptr[p2] == RS
          record_end(buf, p2 + 1, stop)
        else
          keyed_unit_end(buf, pos + 1, stop)
        end
      elsif byte == GS
        p2 = pos
        while p2 < stop && (ptr[p2] == GS || C0.layout?(ptr[p2]))
          p2 += 1
        end
        plain(buf, p2, stop)
      elsif byte == FS
        plain(buf, pos + 1, stop)
      else
        raise SyntaxError.new("BEL before a code that is not an element", pos)
      end
    end

    # From just after an RS, find the end of the record: the next
    # record-level code at this depth. Returns that position.
    def record_end(buf : Bytes, pos : Int32, stop : Int32 = buf.size) : Int32
      ptr = buf.to_unsafe
      while pos < stop
        byte = ptr[pos]
        if byte >= 0x20_u8 || C0.layout?(byte)
          pos += 1
        elsif byte == US
          pos += 1
        elsif byte == SOH
          pos += 1
        elsif byte == STX
          pos = text(buf, pos, stop)
        elsif byte == DLE
          pos = level(buf, pos, stop)
        elsif byte == ENQ
          pos += 1
        elsif byte == BEL
          # a note inside the record, or a dead element; a dead record-level
          # element (BEL RS / BEL GS …) ends this record first.
          p2 = layout(buf, pos + 1, stop)
          if p2 < stop && (ptr[p2] == RS || ptr[p2] == GS || ptr[p2] == FS)
            return pos
          end
          if p2 < stop && ptr[p2] == SOH
            p3 = layout(buf, p2 + 1, stop)
            return pos if p3 < stop && ptr[p3] == RS
          end
          pos = comment(buf, pos, stop)
        else
          return pos
        end
      end
      pos
    end

    # From just after an SOH (not a header row), skip the key, US and
    # value of one keyed unit. Returns the position after the value.
    def keyed_unit_end(buf : Bytes, pos : Int32, stop : Int32 = buf.size) : Int32
      ptr = buf.to_unsafe
      pos = layout(buf, pos, stop)
      pos = plain(buf, pos, stop)
      raise SyntaxError.new("key without a value (no US)", pos) unless pos < stop && ptr[pos] == US
      unit(buf, pos + 1, stop)
    end
  end

  # ---------------------------------------------------------------------
  # Values
  # ---------------------------------------------------------------------

  # Trim layout from both ends of a raw slice.
  def self.trim(raw : Bytes) : Bytes
    s = 0
    e = raw.size
    ptr = raw.to_unsafe
    while s < e && layout?(ptr[s])
      s += 1
    end
    while e > s && layout?(ptr[e - 1])
      e -= 1
    end
    raw[s...e]
  end

  # Whether the raw unit (layout included) is a text value.
  def self.text?(raw : Bytes) : Bool
    t = trim(raw)
    t.size > 0 && t[0] == STX
  end

  # Whether the raw unit is a nested level.
  def self.level?(raw : Bytes) : Bool
    t = trim(raw)
    t.size > 0 && t[0] == DLE
  end

  # Whether the raw unit is a reference.
  def self.reference?(raw : Bytes) : Bool
    t = trim(raw)
    t.size > 0 && t[0] == ENQ
  end

  # The logical value of a raw unit slice: for text, the inside with its
  # escapes decoded (zero-copy when there are none); for a plain value,
  # the slice with edge layout removed. A note in the unit yields the
  # empty value. Raises on malformed input.
  def self.value(raw : Bytes) : Bytes
    t = trim(raw)
    return t if t.size == 0
    first = t[0]
    if first == STX
      stop = Scan.text(t, 0)
      rest = Scan.layout(t, stop)
      raise SyntaxError.new("text cannot be part of a plain value", rest) if rest < t.size
      decode_text(t[1...(stop - 1)])
    elsif first == BEL
      # a note, or a dead level: the unit is empty
      stop = Scan.comment(t, 0)
      rest = Scan.layout(t, stop)
      raise SyntaxError.new("value after a comment in the same unit", rest) if rest < t.size
      Bytes.empty
    elsif first == DLE
      raise SyntaxError.new("a nested level is not a scalar value", 0)
    elsif first == ENQ
      raise SyntaxError.new("a reference is not a scalar value", 0)
    else
      i = 0
      ptr = t.to_unsafe
      while i < t.size
        b = ptr[i]
        if b == BEL
          # a note after the value: skipped
          stop = Scan.comment(t, i)
          rest = Scan.layout(t, stop)
          raise SyntaxError.new("value after a note in the same unit", rest) if rest < t.size
          return trim(t[0...i])
        elsif b < 0x20_u8
          raise SyntaxError.new(layout?(b) ? "layout code inside a plain value" : "control code inside a plain value", i)
        end
        i += 1
      end
      t
    end
  end

  # Decode the inside of a text: DLE escapes removed. Zero-copy when
  # there are none.
  def self.decode_text(inside : Bytes) : Bytes
    i = 0
    ptr = inside.to_unsafe
    while i < inside.size
      return decode_text_slow(inside, i) if ptr[i] == DLE
      i += 1
    end
    inside
  end

  private def self.decode_text_slow(inside : Bytes, first : Int32) : Bytes
    io = IO::Memory.new(inside.size)
    io.write(inside[0, first])
    i = first
    while i < inside.size
      b = inside[i]
      if b == DLE
        i += 1
        raise UnexpectedEndError.new("DLE at end of text", i) if i >= inside.size
        io.write_byte(inside[i])
      else
        io.write_byte(b)
      end
      i += 1
    end
    io.to_slice
  end

  # Whether a value can be written plain: no byte below 0x20, no edge
  # whitespace.
  def self.plain?(value : Bytes) : Bool
    return true if value.size == 0
    return false if layout?(value[0]) || layout?(value[value.size - 1])
    i = 0
    ptr = value.to_unsafe
    while i < value.size
      return false if ptr[i] < 0x20_u8
      i += 1
    end
    true
  end

  # Write a value in its one canonical spelling: plain when it can be,
  # text otherwise, with only the seven codes escaped.
  def self.write_value(io : IO, value : Bytes) : Nil
    if plain?(value)
      io.write(value)
    else
      io.write_byte(STX)
      i = 0
      ptr = value.to_unsafe
      while i < value.size
        b = ptr[i]
        io.write_byte(DLE) if b < 0x20_u8 && TEXT_ESCAPED[b]
        io.write_byte(b)
        i += 1
      end
      io.write_byte(ETX)
    end
  end

  def self.write_value(io : IO, value : String) : Nil
    write_value(io, value.to_slice)
  end

  # Whether a string is a legal name (label, key, header name).
  def self.name?(value : Bytes) : Bool
    plain?(value)
  end

  # Write a name; raises if it is not one.
  def self.write_name(io : IO, name : Bytes) : Nil
    raise Error.new("not a legal name: #{name.inspect}") unless name?(name)
    io.write(name)
  end
end

require "./c0/token"
require "./c0/tokenizer"
require "./c0/validator"
require "./c0/body"
require "./c0/document"
require "./c0/builder"
# require "./c0/pretty"
require "./c0/stream"
# require "./c0/diff"
# require "./c0/csv"
# require "./c0/json"
# require "./c0/serializable"
# require "./c0/core_ext"
