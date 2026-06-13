module C0
  VERSION = "0.9.0"

  # Assigned C0 control codes
  SOH = 0x01_u8 # Header (field name declarations)
  STX = 0x02_u8 # Open nested sub-structure / reference scope
  ETX = 0x03_u8 # Close nested sub-structure / reference scope
  EOT = 0x04_u8 # End of document / message
  ENQ = 0x05_u8 # Reference (enquiry — look up named data)
  DLE = 0x10_u8 # Escape (next byte is literal)
  ETB = 0x17_u8 # Commit marker (stream mode block terminator)
  SUB = 0x1a_u8 # Substitution (old → new, C0-DIFF)
  FS  = 0x1c_u8 # File / Database separator
  GS  = 0x1d_u8 # Group / Table / Section separator
  RS  = 0x1e_u8 # Record / Row separator
  US  = 0x1f_u8 # Unit / Field separator

  # Set of assigned control code bytes for fast lookup
  ASSIGNED = StaticArray[
    false, true,  true,  true,  true,  true,  false, false, # 0x00-0x07
    false, false, false, false, false, false, false, false, # 0x08-0x0F
    true,  false, false, false, false, false, false, true,  # 0x10-0x17
    false, false, true,  false, true,  true,  true,  true,  # 0x18-0x1F
  ]

  # Decode DLE escapes, returning the logical bytes of a value.
  # Zero-copy (returns the input slice) when no escapes are present.
  def self.unescape(buf : Bytes) : Bytes
    i = 0
    len = buf.size
    while i < len
      return unescape_slow(buf, i) if buf[i] == DLE
      i += 1
    end
    buf
  end

  private def self.unescape_slow(buf : Bytes, first : Int32) : Bytes
    io = IO::Memory.new(buf.size)
    io.write(buf[0, first])
    i = first
    len = buf.size
    while i < len
      byte = buf[i]
      if byte == DLE
        i += 1
        raise UnexpectedEndError.new if i >= len
        io.write_byte(buf[i])
      else
        io.write_byte(byte)
      end
      i += 1
    end
    io.to_slice
  end

  # Whether bytes are a canonical document unit for content addressing
  # (see DESIGN.md "Canonical Form"): well-formed, minimally escaped
  # (DLE appears only before bytes < 0x20), and free of framing bytes
  # (ETB, EOT). Stream logs validate per-block, not with this check.
  def self.canonical?(buf : Bytes) : Bool
    i = 0
    len = buf.size
    while i < len
      byte = buf[i]
      if byte == DLE
        return false if i + 1 >= len        # dangling escape
        return false if buf[i + 1] >= 0x20  # gratuitous escape
        i += 2
      elsif byte == ETB || byte == EOT
        return false                        # framing in a document unit
      elsif byte < 0x20
        return false unless ASSIGNED[byte]  # unassigned code
        i += 1
      else
        i += 1
      end
    end
    true
  end
end

require "./c0/token"
require "./c0/tokenizer"
require "./c0/table"
require "./c0/document"
require "./c0/builder"
require "./c0/pretty"
require "./c0/stream"
require "./c0/diff"
require "./c0/csv"
require "./c0/json"
require "./c0/serializable"
require "./c0/core_ext"
