module C0
  # The heading of a document: keyed units after SYN, in written order,
  # superseded keys dropped. A duplicate key is reported as written; `[]`
  # resolves last-wins.
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

    # The schema the body claims: a name, or the keyed record of name, url
    # and hash as a Record; nil when absent.
    def schema : Bytes?
      self["schema"]
    end

    # The blob table as a Body, when declared as a level (anything else
    # declares nothing; see Container#warnings).
    def blob : Body?
      raw_blob.try { |r| r.size > 0 && r[0] == DLE ? Body.new(r, 1, Scan.level(r, 0) - 1, level: true) : nil }
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
    SHAPES = {"diff", "stream"}
    KEYS   = {"shape", "schema", "version", "blob"}

    getter buf : Bytes
    getter heading : Heading
    getter body : Body
    getter start : Int32
    getter stop : Int32 # position after EOT (or end of document)
    getter? has_syn : Bool
    getter? has_eot : Bool
    # Loud warnings (DESIGN.md, Warnings).
    getter warnings : Array(String)

    def initialize(@buf : Bytes, @start : Int32 = 0, stop : Int32? = nil, parser : Parser? = nil)
      @warnings = Array(String).new
      ptr = @buf.to_unsafe
      len = stop || @buf.size.to_i32
      p = parser || Parser.new(@buf)
      pos = p.layout(@start, len)
      @has_syn = pos < len && ptr[pos] == SYN
      if @has_syn
        p.not_canonical("SYN in a canonical span")
        @heading, pos = p.heading(pos + 1, len)
      else
        @warnings << "no SYN at the start of the document"
        @heading = Heading.empty
      end
      body_start = pos
      files, pos = p.body(pos, len, level: false)
      @body = Body.new(@buf, body_start, pos, files)
      pos = p.layout(pos, len)
      @has_eot = pos < len && ptr[pos] == EOT
      if @has_eot
        p.not_canonical("EOT in a canonical span")
        pos += 1
      elsif @heading.shape != "stream"
        @warnings << "no EOT at the end of the document"
      end
      @stop = pos
      seen = Set(Bytes).new
      @heading.keys.each do |k|
        s = String.new(k)
        @warnings << "unknown heading key '#{s}'" unless KEYS.includes?(s)
        @warnings << "duplicate heading key '#{s}': last wins" unless seen.add?(k)
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

    # Parse buf[0...stop]. The tail after EM runs to the end of the buffer.
    def initialize(buf : Bytes, stop : Int32? = nil, parser : Parser? = nil)
      @documents = Array(Document).new
      @tail = Bytes.empty
      @has_em = false
      @warnings = Array(String).new
      ptr = buf.to_unsafe
      len = stop || buf.size.to_i32
      p = parser || Parser.new(buf)
      pos = p.layout(0, len)
      first = true
      while pos < len
        if ptr[pos] == EM
          p.not_canonical("EM in a canonical span")
          @has_em = true
          @tail = buf[(pos + 1)...buf.size]
          break
        end
        raise SyntaxError.new("a document after the first must begin with SYN", pos) unless first || ptr[pos] == SYN
        doc = Document.new(buf, pos, len, p)
        first = false
        @documents << doc
        pos = p.layout(doc.stop, len)
        if pos < len && ptr[pos] != SYN && ptr[pos] != EM
          raise SyntaxError.new(doc.has_eot? ? "unexpected byte after EOT" : "unexpected byte after document", pos)
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
