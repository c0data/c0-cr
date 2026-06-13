module C0
  class Error < Exception; end

  class UnassignedCodeError < Error
    getter byte : UInt8
    getter position : Int32

    def initialize(@byte, @position)
      super("Unassigned control code 0x#{@byte.to_s(16).rjust(2, '0')} at position #{@position}")
    end
  end

  class UnexpectedEndError < Error
    def initialize
      super("Unexpected end of input after DLE escape")
    end
  end

  # High-performance zero-copy tokenizer for C0DATA.
  #
  # Scans a byte buffer for control codes (< 0x20) and emits tokens as
  # offsets into the original buffer. No allocation for data values.
  #
  # The hot loop is a single comparison: `byte < 0x20`.
  struct Tokenizer
    @buf : Bytes
    @pos : Int32
    @len : Int32

    def initialize(@buf : Bytes)
      @pos = 0
      @len = @buf.size.to_i32
    end

    # Yields each token to the block. This is the primary interface
    # for streaming consumption.
    def each(& : Token ->) : Nil
      while @pos < @len
        byte = @buf.to_unsafe[@pos]

        if byte < 0x20_u8
          handle_control(byte) { |token| yield token }
        else
          yield scan_data
        end
      end
    end

    # Collects all tokens into an array. Convenience method for
    # non-streaming use. Prefer `each` for performance.
    def to_a : Array(Token)
      tokens = Array(Token).new
      each { |t| tokens << t }
      tokens
    end

    # Scans a run of data bytes (>= 0x20). Returns a single Data token
    # spanning the entire run.
    @[AlwaysInline]
    private def scan_data : Token
      start = @pos
      ptr = @buf.to_unsafe

      @pos += 1
      while @pos < @len
        break if ptr[@pos] < 0x20_u8
        @pos += 1
      end

      Token.new(TokenType::Data, start, @pos)
    end

    # Handles a control byte at the current position.
    @[AlwaysInline]
    private def handle_control(byte : UInt8, & : Token ->) : Nil
      case byte
      when C0::DLE
        yield scan_escape
      when C0::SOH then yield_control(TokenType::SOH) { |t| yield t }
      when C0::STX then yield_control(TokenType::STX) { |t| yield t }
      when C0::ETX then yield_control(TokenType::ETX) { |t| yield t }
      when C0::EOT then yield_control(TokenType::EOT) { |t| yield t }
      when C0::ENQ then yield_control(TokenType::ENQ) { |t| yield t }
      when C0::ETB then yield_control(TokenType::ETB) { |t| yield t }
      when C0::SUB then yield_control(TokenType::SUB) { |t| yield t }
      when C0::FS  then yield_control(TokenType::FS)  { |t| yield t }
      when C0::GS  then yield_control(TokenType::GS)  { |t| yield t }
      when C0::RS  then yield_control(TokenType::RS)  { |t| yield t }
      when C0::US  then yield_control(TokenType::US)  { |t| yield t }
      else
        raise UnassignedCodeError.new(byte, @pos)
      end
    end

    # Emits a single-byte control token and advances position.
    @[AlwaysInline]
    private def yield_control(type : TokenType, & : Token ->) : Nil
      token = Token.new(type, @pos, @pos + 1)
      @pos += 1
      yield token
    end

    # Handles DLE escape: consumes DLE + next byte, emits a Data token
    # for the escaped byte.
    @[AlwaysInline]
    private def scan_escape : Token
      @pos += 1 # skip DLE
      raise UnexpectedEndError.new if @pos >= @len

      # The escaped byte is data, regardless of its value.
      token = Token.new(TokenType::Data, @pos, @pos + 1)
      @pos += 1
      token
    end
  end
end
