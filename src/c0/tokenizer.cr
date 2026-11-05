module C0
  # Zero-copy tokenizer. Scans a byte buffer and emits tokens as offsets
  # into it: plain runs, layout runs, whole texts, and one token per code.
  # It does not check structure (see Validator); it stops the raw region
  # at EM and raises on unassigned codes and malformed text.
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

    # Position of the first byte after EM, or the buffer size.
    getter tail_start : Int32 = -1

    def each(& : Token ->) : Nil
      ptr = @buf.to_unsafe
      while @pos < @len
        byte = ptr[@pos]
        if byte < 0x20_u8
          case byte
          when STX
            stop = Scan.text(@buf, @pos)
            yield Token.new(TokenType::Text, @pos, stop)
            @pos = stop
          when HT, LF, CR
            yield scan_layout
          when EM
            yield Token.new(TokenType::EM, @pos, @pos + 1)
            @pos += 1
            @tail_start = @pos
            return
          when SOH then yield_code(TokenType::SOH) { |t| yield t }
          when EOT then yield_code(TokenType::EOT) { |t| yield t }
          when ENQ then yield_code(TokenType::ENQ) { |t| yield t }
          when BEL then yield_code(TokenType::BEL) { |t| yield t }
          when DLE then yield_code(TokenType::DLE) { |t| yield t }
          when SYN then yield_code(TokenType::SYN) { |t| yield t }
          when ETB then yield_code(TokenType::ETB) { |t| yield t }
          when CAN then yield_code(TokenType::CAN) { |t| yield t }
          when SUB then yield_code(TokenType::SUB) { |t| yield t }
          when FS  then yield_code(TokenType::FS) { |t| yield t }
          when GS  then yield_code(TokenType::GS) { |t| yield t }
          when RS  then yield_code(TokenType::RS) { |t| yield t }
          when US  then yield_code(TokenType::US) { |t| yield t }
          else
            raise UnassignedCodeError.new(byte, @pos)
          end
        elsif byte == SP
          yield scan_layout
        else
          yield scan_data
        end
      end
      @tail_start = @len
    end

    def to_a : Array(Token)
      tokens = Array(Token).new
      each { |t| tokens << t }
      tokens
    end

    # A plain run: bytes >= 0x20, ending before trailing spaces so that
    # layout next to a code is its own token.
    @[AlwaysInline]
    private def scan_data : Token
      start = @pos
      ptr = @buf.to_unsafe
      @pos += 1
      while @pos < @len && ptr[@pos] >= 0x20_u8
        @pos += 1
      end
      stop = @pos
      while stop > start + 1 && ptr[stop - 1] == SP
        stop -= 1
      end
      @pos = stop
      Token.new(TokenType::Data, start, stop)
    end

    @[AlwaysInline]
    private def scan_layout : Token
      start = @pos
      @pos = Scan.layout(@buf, @pos)
      Token.new(TokenType::Layout, start, @pos)
    end

    @[AlwaysInline]
    private def yield_code(type : TokenType, & : Token ->) : Nil
      token = Token.new(type, @pos, @pos + 1)
      @pos += 1
      yield token
    end
  end
end
