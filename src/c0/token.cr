module C0
  enum TokenType
    # Data content between control codes
    Data

    # Structural control codes
    SOH # Header
    STX # Open nested structure
    ETX # Close nested structure
    EOT # End of document
    ENQ # Reference
    DLE # Escape (consumed during tokenization, not emitted)
    ETB # Commit marker (stream mode)
    SUB # Substitution
    FS  # File separator
    GS  # Group separator
    RS  # Record separator
    US  # Unit separator
  end

  struct Token
    getter type : TokenType
    getter start : Int32
    getter end : Int32

    def initialize(@type : TokenType, @start : Int32, @end : Int32)
    end

    # Returns the byte length of this token's data.
    @[AlwaysInline]
    def size : Int32
      @end - @start
    end

    # Returns the value as a slice into the given buffer. Zero-copy.
    @[AlwaysInline]
    def value(buf : Bytes) : Bytes
      buf[@start...@end]
    end
  end
end
