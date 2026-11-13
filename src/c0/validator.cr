module C0
  # Checks a buffer against GRAMMAR.md by parsing it with the Parser.
  # `validate` raises the first error; `canonical?` additionally applies
  # the canonical constraints and answers false instead of raising.
  struct Validator
    @buf : Bytes
    @parser : Parser

    def initialize(@buf : Bytes, canonical : Bool = false)
      @parser = Parser.new(@buf, canonical: canonical)
    end

    # Raise on the first structural error.
    def self.validate(buf : Bytes) : Nil
      Validator.new(buf).run
    end

    # Well-formed and canonical: no layout, one spelling per value, keys
    # unique within a keyed record, no framing, no comments. Supersession
    # is content and is kept.
    def self.canonical?(buf : Bytes) : Bool
      v = Validator.new(buf, canonical: true)
      begin
        v.run
      rescue Error
        return false
      end
      v.ok?
    end

    # Parse the whole buffer as a container of documents.
    def run : Nil
      Container.new(@buf, parser: @parser)
    end

    def ok? : Bool
      @parser.ok?
    end

    # The canonical violations met.
    def warnings : Array(String)
      @parser.warnings
    end
  end

  def self.validate(buf : Bytes) : Nil
    Validator.validate(buf)
  end

  # Whether bytes are a canonical span (DESIGN.md "Canonical Form").
  def self.canonical?(buf : Bytes) : Bool
    Validator.canonical?(buf)
  end
end
