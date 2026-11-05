module C0
  enum TokenType
    Data   # a plain run of bytes >= 0x20 (may include interior spaces)
    Layout # a run of layout bytes (SP HT LF CR) outside text
    Text   # a whole text, STX through ETX

    SOH # key or header-row introducer
    EOT # end of document
    ENQ # reference
    BEL # comment introducer
    DLE # open a nested level
    SYN # start of document
    ETB # commit marker
    CAN # close a nested level
    EM  # end of medium
    SUB # substitution
    FS  # file separator
    GS  # group separator
    RS  # record separator
    US  # unit separator
  end

  struct Token
    getter type : TokenType
    getter start : Int32
    getter end : Int32

    def initialize(@type : TokenType, @start : Int32, @end : Int32)
    end

    @[AlwaysInline]
    def size : Int32
      @end - @start
    end

    # Raw bytes of the token as a slice into the buffer. Zero-copy.
    @[AlwaysInline]
    def raw(buf : Bytes) : Bytes
      buf[@start...@end]
    end

    # For a Text token: the inside, escapes decoded.
    def text(buf : Bytes) : Bytes
      C0.decode_text(buf[(@start + 1)...(@end - 1)])
    end
  end
end
