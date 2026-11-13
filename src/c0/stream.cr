module C0
  # Stream mode: ETB-committed append logs (DESIGN.md "Stream Mode").
  #
  #   C0::Stream::Writer.open("events.c0") do |w|
  #     w.record("create", "a1b2", "1718208000")
  #   end
  #   r = C0::Stream::Reader.read("events.c0")
  #   r.torn?          # => false
  #   r.each_record { |rec| ... }
  module Stream
    # A committed block that is not well-formed (DESIGN.md, Damaged
    # Blocks). `resume_offset` is where reading can go on, after the
    # block's ETB and payload.
    class DamagedBlockError < C0::Error
      getter index : Int32
      getter resume_offset : Int32

      def initialize(@index : Int32, @resume_offset : Int32)
        super("block #{@index} is damaged; reading can resume at byte #{@resume_offset}")
      end
    end

    # Scans a buffer for commits. An unescaped ETB is always a commit,
    # even inside open text or a level. A committed block that is not
    # well-formed, cut by its ETB or holding any other error, is damaged:
    # nothing in it is delivered, and by default the reader delivers the
    # records before it and then raises DamagedBlockError; with
    # `continue_past_damage` it reads on past the block. The tail after
    # the last commit is torn unless it holds only layout, notes or EOT.
    class Reader
      getter buf : Bytes
      getter committed_end : Int32
      getter blocks : Array({Int32, Int32})   # [start, end) of each committed block (ETB excluded)
      getter damaged : Array(Int32)           # indexes of damaged blocks
      getter? torn : Bool
      getter? continue_past_damage : Bool

      def initialize(@buf : Bytes, @continue_past_damage : Bool = false)
        @committed_end = 0
        @blocks = Array({Int32, Int32}).new
        @damaged = Array(Int32).new
        @torn = false
        @container = nil
        scan
        parse_committed
      end

      @container : Container?

      def self.read(path : Path | String, continue_past_damage : Bool = false) : Reader
        new(File.read(path).to_slice, continue_past_damage)
      end

      def committed : Bytes
        @buf[0...@committed_end]
      end

      def tail : Bytes
        @buf[@committed_end...@buf.size]
      end

      def block_count : Int32
        @blocks.size
      end

      def block(i : Int32) : Bytes
        s, e = @blocks[i]
        @buf[s...e]
      end

      def damaged?(i : Int32) : Bool
        @damaged.includes?(i)
      end

      def each_block(& : Bytes ->) : Nil
        @blocks.size.times { |i| yield block(i) }
      end

      # Offset after a block's ETB and payload: the start of the next block.
      def block_end(i : Int32) : Int32
        i + 1 < @blocks.size ? @blocks[i + 1][0] : @committed_end
      end

      # The committed region as documents, damaged blocks left out. Raises
      # DamagedBlockError when a block is damaged, unless continuing.
      def container : Container
        check_damage
        @container.not_nil!
      end

      # The first document of the committed region.
      def document : Document
        container.first
      end

      def body : Body
        document.body
      end

      # Compatibility: the committed records as a group.
      def table : Group
        b = body
        b.groups.first? || Group.new(Bytes.empty, 0, 0, 0, nil, Array(Record).new)
      end

      # Every committed record in order, up to the first damaged block;
      # then DamagedBlockError, unless continuing, in which case every
      # record of every sound block.
      def each_record(& : Record ->) : Nil
        c = @container.not_nil!
        limit = Int32::MAX
        unless @continue_past_damage
          if d = @damaged.first?
            limit = @blocks[d][0]
          end
        end
        c.documents.each do |doc|
          doc.body.groups.each do |g|
            g.records.each do |r|
              check_damage if r.offset >= limit
              yield r
            end
          end
        end
        check_damage
      end

      def records : Array(Record)
        out = Array(Record).new
        each_record { |r| out << r }
        out
      end

      private def check_damage : Nil
        return if @continue_past_damage
        if d = @damaged.first?
          raise DamagedBlockError.new(d, block_end(d))
        end
      end

      # Parse the committed region. Any error inside a committed block
      # marks that block damaged; the region is then parsed again with the
      # block skipped, so what follows is read in the context before it.
      private def parse_committed : Nil
        skip = Hash(Int32, Int32).new
        loop do
          parser = Parser.new(@buf, skip: skip)
          begin
            @container = Container.new(@buf, stop: @committed_end, parser: parser)
            break
          rescue e : SyntaxError
            i = block_at(e.position)
            raise e if i.nil? || skip.has_key?(@blocks[i][0])
            @damaged << i
            skip[@blocks[i][0]] = block_end(i)
          end
        end
        @damaged.sort!
      end

      # The block holding byte `pos` of the committed region.
      private def block_at(pos : Int32) : Int32?
        found = nil
        @blocks.each_with_index do |(s, _e), i|
          found = i if s <= pos
        end
        found
      end

      private def scan : Nil
        ptr = @buf.to_unsafe
        len = @buf.size.to_i32
        pos = 0
        block_start = 0
        in_text = false
        depth = 0
        while pos < len
          b = ptr[pos]
          if in_text
            if b == DLE
              pos += 2
              next
            elsif b == ETX
              in_text = false
            elsif b == ETB
              commit(block_start, pos)
              pos = payload_end(pos + 1)
              block_start = pos
              in_text = false
              depth = 0
              next
            elsif b == SYN || b == EOT || b == EM
              # framing cuts the text; the block is torn/damaged at the next commit
              in_text = false
              depth = 0
              if b == SYN
                block_start = pos
              end
            end
            pos += 1
          else
            if b == STX
              in_text = true
            elsif b == DLE
              depth += 1
            elsif b == CAN
              depth -= 1 if depth > 0
            elsif b == ETB
              commit(block_start, pos)
              pos = payload_end(pos + 1)
              block_start = pos
              depth = 0
              next
            elsif b == SYN && pos > 0
              # tears the uncommitted bytes before it; a new document begins
              block_start = pos
              depth = 0
            end
            pos += 1
          end
        end
        @torn = torn_tail?
      end

      private def commit(start : Int32, stop : Int32) : Nil
        @blocks << {start, stop}
      end

      # After an ETB: skip its payload and return committed_end (which
      # excludes layout after the payload).
      private def payload_end(pos : Int32) : Int32
        ptr = @buf.to_unsafe
        len = @buf.size.to_i32
        p = Scan.layout(@buf, pos, len)
        if p < len && ptr[p] >= 0x20_u8
          while p < len && ptr[p] >= 0x20_u8
            p += 1
          end
          # trailing spaces of the payload are layout
          while p > pos && ptr[p - 1] == SP
            p -= 1
          end
        else
          p = pos # no payload: layout after ETB belongs to the next block
        end
        @committed_end = p
        p
      end

      # Is the tail more than layout, notes and EOT?
      private def torn_tail? : Bool
        ptr = @buf.to_unsafe
        len = @buf.size.to_i32
        pos = @committed_end
        loop do
          pos = Scan.layout(@buf, pos, len)
          return false if pos >= len
          b = ptr[pos]
          if b == EOT
            pos += 1
          elsif b == EM
            return false # the raw region is not data of the log
          elsif b == BEL
            p2 = Scan.layout(@buf, pos + 1, len)
            return true if p2 < len && ptr[p2] < 0x20_u8 && ptr[p2] != STX # a dead element is data
            begin
              pos = Scan.comment(@buf, pos, len)
            rescue Error
              return true
            end
          else
            return true
          end
        end
      end
    end

    # Appends committed blocks to an IO or file. Each `record`, `header`,
    # `group` or `batch` is one block, written with its ETB in a single
    # append.
    class Writer
      @io : IO
      @sync : Bool

      def initialize(@io : IO, @sync : Bool = false)
      end

      def self.open(path : Path | String, sync : Bool = true) : Writer
        repair(path) if File.exists?(path)
        new(File.new(path, "a"), sync)
      end

      def self.open(path : Path | String, sync : Bool = true, & : Writer ->) : Nil
        w = open(path, sync)
        begin
          yield w
        ensure
          w.close
        end
      end

      # Truncate an uncommitted tail so the file ends at a commit.
      def self.repair(path : Path | String) : Nil
        buf = File.read(path).to_slice
        r = Reader.new(buf)
        if r.torn?
          File.open(path, "r+") { |f| f.truncate(r.committed_end) }
        end
      end

      # A new log: SYN and heading, committed.
      def start(pairs : Hash(String, String) = {"shape" => "stream"}) : Nil
        commit { |b| b.syn(pairs) }
      end

      def record(*fields : String) : Nil
        record(fields)
      end

      def record(fields : Indexable(String)) : Nil
        commit { |b| b.record(fields) }
      end

      def map(pairs : Hash(String, String)) : Nil
        commit { |b| b.map(pairs) }
      end

      def header(*names : String) : Nil
        header(names)
      end

      def header(names : Indexable(String)) : Nil
        commit { |b| b.header(names) }
      end

      def group(name : String, headers : Indexable(String)? = nil) : Nil
        commit { |b| b.group(name, headers) }
      end

      # Several writes under one ETB: atomic as a batch.
      def batch(& : Builder ->) : Nil
        commit { |b| yield b }
      end

      def flush : Nil
        @io.flush
        if @sync && (f = @io).is_a?(File)
          f.fsync
        end
      end

      def close : Nil
        flush
        @io.close
      end

      private def commit(& : Builder ->) : Nil
        b = Builder.new
        yield b
        b.etb
        @io.write(b.to_slice)
        flush
      end
    end

    # Position just past the last commit, found by scanning backward.
    def self.last_commit_end(buf : Bytes) : Int32
      ptr = buf.to_unsafe
      i = buf.size - 1
      while i >= 0
        if ptr[i] == ETB
          # count the DLE run before it: odd means escaped
          dles = 0
          j = i - 1
          while j >= 0 && ptr[j] == DLE
            dles += 1
            j -= 1
          end
          if dles.even?
            p = i + 1
            while p < buf.size && ptr[p] >= 0x20_u8
              p += 1
            end
            return p
          end
        end
        i -= 1
      end
      0
    end
  end
end
