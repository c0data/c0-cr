module C0
  # The heading of a document: keyed units after SYN. Last wins for
  # duplicate keys.
  struct Heading
    getter pairs : Array({Bytes, Bytes})
    getter raw : Bytes

    def initialize(@raw : Bytes, @pairs : Array({Bytes, Bytes}))
    end

    def self.empty : Heading
      new(Bytes.empty, Array({Bytes, Bytes}).new)
    end

    def [](key : String) : Bytes?
      found = nil
      @pairs.each { |k, v| found = v if k == key.to_slice }
      found
    end

    def keys : Array(Bytes)
      @pairs.map(&.[0])
    end

    def shape : String?
      self["shape"].try { |v| String.new(v) }
    end

    def version : Int32
      self["version"].try { |v| String.new(v).to_i? } || 1
    end

    # The blob table as a Body, when declared as a level (anything else
    # declares nothing; see Container#warnings).
    def blob : Body?
      raw_blob.try { |r| r.size > 0 && r[0] == DLE ? Body.new(r, 1, Scan.level(r, 0) - 1) : nil }
    end

    # Raw unit of the blob key (a level), or nil.
    def raw_blob : Bytes?
      found = nil
      @pairs_raw.try &.each { |k, v| found = v if k == "blob".to_slice }
      found
    end

    @pairs_raw : Array({Bytes, Bytes})? = nil

    protected def pairs_raw=(v : Array({Bytes, Bytes}))
      @pairs_raw = v
    end

    def empty? : Bool
      @pairs.empty?
    end
  end

  # One C0DATA document: an optional SYN heading, a body, an optional EOT.
  # `Document.new(buf)` reads the first document in the buffer. Use
  # `Container` for a buffer holding several documents or an EM tail.
  struct Document
    SHAPES = {"diff", "stream", "tabular", "document", "key-value"}

    getter buf : Bytes
    getter heading : Heading
    getter body : Body
    getter start : Int32
    getter stop : Int32 # position after EOT (or end of document)
    getter? has_syn : Bool
    getter? has_eot : Bool
    getter warnings : Array(String)

    def initialize(@buf : Bytes, @start : Int32 = 0)
      @warnings = Array(String).new
      ptr = @buf.to_unsafe
      len = @buf.size.to_i32
      pos = Scan.layout(@buf, @start, len)
      @has_syn = pos < len && ptr[pos] == SYN
      if @has_syn
        pos += 1
        @heading, pos = Document.parse_heading(@buf, pos, len)
      else
        @warnings << "no SYN at the start of the document"
        @heading = Heading.empty
      end
      body_start = pos
      body_end = Document.find_body_end(@buf, pos, len)
      @body = Body.new(@buf, body_start, body_end)
      pos = Scan.layout(@buf, body_end, len)
      @has_eot = pos < len && ptr[pos] == EOT
      if @has_eot
        pos += 1
      elsif @heading.shape != "stream"
        @warnings << "no EOT at the end of the document"
      end
      @stop = pos
      @heading.keys.each do |k|
        s = String.new(k)
        @warnings << "unknown heading key '#{s}'" unless s == "shape" || s == "version" || s == "blob"
      end
      if (sh = @heading.shape) && !SHAPES.includes?(sh)
        @warnings << "unknown shape '#{sh}'"
      end
      if (v = @heading["version"]) && String.new(v) != "1"
        @warnings << "unknown version '#{String.new(v)}'"
      end
    end

    # Convenience accessors over the body.
    def name : Bytes
      @body.name
    end

    def files : Array(FileView)
      @body.files
    end

    def group_count : Int32
      @body.group_count
    end

    def group(i : Int32) : Group
      @body.group(i)
    end

    def group(name : String) : Group
      @body.group(name)
    end

    def [](name : String) : Group
      group(name)
    end

    def [](i : Int32) : Group
      group(i)
    end

    def each_group(& : Group ->) : Nil
      @body.each_group { |g| yield g }
    end

    def groups : Array(Group)
      @body.groups
    end

    def group_names : Array(Bytes)
      @body.group_names
    end

    def records : Array(Record)
      @body.records
    end

    def shape : String?
      @heading.shape
    end

    def raw : Bytes
      @buf[@start...@stop]
    end

    # Parse keyed units after SYN. Returns {heading, position of first body code}.
    protected def self.parse_heading(buf : Bytes, pos : Int32, len : Int32) : {Heading, Int32}
      ptr = buf.to_unsafe
      hs = pos
      pairs = Array({Bytes, Bytes}).new
      raw_pairs = Array({Bytes, Bytes}).new
      loop do
        pos = Scan.layout(buf, pos, len)
        break if pos >= len
        b = ptr[pos]
        if b == SOH
          p2 = Scan.layout(buf, pos + 1, len)
          break if p2 < len && ptr[p2] == RS
          ks = p2
          ke = Scan.plain(buf, ks, len)
          raise SyntaxError.new("key without a value (no US)", ke) unless ke < len && ptr[ke] == US
          vs = ke + 1
          ve = Scan.unit(buf, vs, len)
          key = C0.trim(buf[ks...ke])
          rawv = C0.trim(buf[vs...ve])
          raise SyntaxError.new("reference in a heading", vs) if rawv.size > 0 && rawv[0] == ENQ
          raw_pairs << {key, rawv}
          pairs << {key, rawv.size > 0 && rawv[0] == DLE ? rawv : C0.value(rawv)}
          pos = ve
        elsif b == BEL
          # a note or a dead keyed unit belongs to the heading; a dead body
          # element (record, header row, group, file, level) begins the body
          p2 = Scan.layout(buf, pos + 1, len)
          break if p2 >= len
          c = ptr[p2]
          if c == SOH
            p3 = Scan.layout(buf, p2 + 1, len)
            break if p3 < len && ptr[p3] == RS # dead header row
          elsif c < 0x20_u8 && c != STX
            break
          end
          pos = Scan.comment(buf, pos, len)
        elsif b >= 0x20_u8
          raise SyntaxError.new("plain text directly after SYN", pos)
        else
          break
        end
      end
      h = Heading.new(buf[hs...pos], pairs)
      h.pairs_raw = raw_pairs
      {h, pos}
    end

    # Scan from the start of a body to its end: EOT, SYN, EM or end of input
    # at depth zero, skipping text and levels.
    protected def self.find_body_end(buf : Bytes, pos : Int32, len : Int32) : Int32
      ptr = buf.to_unsafe
      while pos < len
        b = ptr[pos]
        if b >= 0x20_u8
          pos += 1
        elsif b == STX
          pos = Scan.text(buf, pos, len)
        elsif b == DLE
          pos = Scan.level(buf, pos, len)
        elsif b == EOT || b == SYN || b == EM
          return pos
        elsif b == CAN
          raise SyntaxError.new("CAN with no open level", pos)
        else
          pos += 1
        end
      end
      pos
    end
  end

  # A file or message: one or more documents and an optional raw tail
  # after EM.
  struct Container
    getter documents : Array(Document)
    getter tail : Bytes
    getter? has_em : Bool
    # Loud warnings about the container as a whole; each document carries
    # its own.
    getter warnings : Array(String)

    def initialize(buf : Bytes)
      @documents = Array(Document).new
      @tail = Bytes.empty
      @has_em = false
      @warnings = Array(String).new
      ptr = buf.to_unsafe
      len = buf.size.to_i32
      pos = Scan.layout(buf, 0, len)
      while pos < len
        if ptr[pos] == EM
          @has_em = true
          @tail = buf[(pos + 1)...len]
          break
        end
        doc = Document.new(buf, pos)
        @documents << doc
        pos = Scan.layout(buf, doc.stop, len)
        if pos < len && ptr[pos] != SYN && ptr[pos] != EM
          raise SyntaxError.new("unexpected byte after EOT", pos)
        end
      end
      @documents.each_with_index do |doc, i|
        next unless raw = doc.heading.raw_blob
        if i > 0
          @warnings << "blob table in a later heading is ignored"
        elsif raw.size == 0 || raw[0] != DLE
          @warnings << "blob is not a level: declares nothing"
        elsif !(doc.heading.blob.try { |b| b.groups.first?.try(&.has_header?) })
          @warnings << "blob table has no header row: declares nothing"
        end
      end
      @warnings << "EM with no blob table: the region is unaddressable" if @has_em && blob.nil?
    end

    def first : Document
      @documents[0]
    end

    # The blob table from the first document's heading.
    def blob : Body?
      @documents[0]?.try(&.heading.blob)
    end

    # Bytes of a named blob from the tail, or nil.
    def blob(name : String) : Bytes?
      table = blob
      return nil unless table
      recs = table.records
      recs = table.groups.first.records if recs.empty? && !table.groups.empty?
      g = table.groups.first? || return nil
      ni = g.column("name") || 0
      oi = g.column("offset") || 1
      li = g.column("length") || 2
      found = nil
      g.records.each do |r|
        next unless r.value(ni) == name.to_slice
        off = String.new(r.value(oi)).to_i
        length = String.new(r.value(li)).to_i
        found = @tail[off, length]
      end
      found
    end
  end
end
