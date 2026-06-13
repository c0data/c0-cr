module C0
  # Stream mode: ETB commits for append-only logs.
  #
  # C0DATA records are start-delimited, so a crashed append leaves a
  # truncated final record that is indistinguishable from a complete one.
  # In stream mode every appended block (one or more records, or an SOH
  # header) is terminated by an ETB commit marker:
  #
  #   [RS]create[US]a1b2c3[ETB][RS]name[US]draft-2[ETB]
  #
  # A block is complete if and only if it is terminated by ETB.
  # `Stream::Reader` exposes only committed data and reports any torn
  # tail. `Stream::Writer` appends each block and its ETB as a single
  # write, and repairs an uncommitted tail before appending — blind
  # appends after a torn tail are unsafe (a tail ending in a bare DLE
  # would escape the next append's RS and fuse two records).
  module Stream
    # Scans a buffer for ETB commit markers and exposes only the
    # committed region. Zero-copy: all accessors return slices into
    # the original buffer.
    #
    #   reader = C0::Stream::Reader.new(buf)
    #   reader.torn?           # => true if an uncommitted tail trails
    #   reader.each_record { |rec| ... }   # committed records only
    struct Reader
      getter buf : Bytes

      def initialize(@buf : Bytes)
        @commits = Array({Int32, Int32}).new # {etb offset, end of payload}
        scan
      end

      # Read a log file into a Reader.
      def self.read(path : Path | String) : Reader
        new(File.open(path, &.getb_to_end))
      end

      # Offset just past the last commit marker and its payload.
      # Zero if the buffer contains no commits.
      def committed_end : Int32
        @commits.empty? ? 0 : @commits.last[1]
      end

      # The committed region of the buffer.
      def committed : Bytes
        @buf[0, committed_end]
      end

      # Uncommitted trailing bytes — residue of an interrupted append.
      def tail : Bytes
        @buf[committed_end..]
      end

      # True if uncommitted bytes trail the last commit marker.
      def torn? : Bool
        committed_end < @buf.size
      end

      # Number of committed blocks.
      def block_count : Int32
        @commits.size
      end

      # Committed block by index: the bytes between the previous commit
      # and this block's ETB (marker and payload excluded).
      def block(i : Int32) : Bytes
        start = i == 0 ? 0 : @commits[i - 1][1]
        @buf[start...@commits[i][0]]
      end

      # Iterate committed blocks.
      def each_block(& : Bytes ->) : Nil
        @commits.size.times { |i| yield block(i) }
      end

      # The committed region as a Table (handles an optional GS name
      # and SOH header, then RS records).
      def table : Table
        Table.new(committed)
      end

      # Iterate committed records.
      def each_record(& : Record ->) : Nil
        table.each_record { |r| yield r }
      end

      # Find every ETB at structural level: DLE-escaped bytes are data,
      # and ETB inside an STX/ETX scope is record content, not a commit.
      private def scan : Nil
        pos = 0
        len = @buf.size.to_i32
        ptr = @buf.to_unsafe

        while pos < len
          byte = ptr[pos]
          if byte == DLE
            pos += 2
          elsif byte == STX
            pos = skip_nested(ptr, pos, len)
          elsif byte == ETB
            etb_pos = pos
            pos += 1
            # Payload runs until the next control code
            while pos < len && ptr[pos] >= 0x20_u8
              pos += 1
            end
            @commits << {etb_pos, pos}
          else
            pos += 1
          end
        end
      end

      private def skip_nested(ptr : Pointer(UInt8), pos : Int32, stop : Int32) : Int32
        pos += 1 # skip STX
        depth = 1
        while pos < stop && depth > 0
          byte = ptr[pos]
          if byte == STX
            depth += 1
          elsif byte == ETX
            depth -= 1
          elsif byte == DLE
            pos += 1
          end
          pos += 1
        end
        pos
      end
    end

    # Appends ETB-committed blocks to an append-only log.
    #
    #   C0::Stream::Writer.open("claims.c0") do |log|
    #     log.record("create", nonce, ts)
    #     log.batch do |b|
    #       b.record("name", label, ts)
    #       b.record("tag", tags, ts)
    #     end
    #   end
    #
    # Each block and its ETB are issued as a single write. `open` repairs
    # a torn tail (truncates to the last commit) before appending.
    class Writer
      # When true and the underlying IO is a File, fsync after each commit.
      property sync : Bool

      def initialize(@io : IO, @sync : Bool = false)
      end

      # Open a log file for appending, repairing any torn tail first.
      def self.open(path : Path | String, sync : Bool = true) : Writer
        repair(path)
        new(File.new(path, "a"), sync: sync)
      end

      def self.open(path : Path | String, sync : Bool = true, & : Writer ->) : Nil
        writer = open(path, sync)
        begin
          yield writer
        ensure
          writer.close
        end
      end

      # Truncate an uncommitted tail so the log ends at a commit marker.
      def self.repair(path : Path | String) : Nil
        return unless File.exists?(path)
        reader = Reader.read(path)
        if reader.torn?
          File.open(path, "r+", &.truncate(reader.committed_end))
        end
      end

      # Append one record as a committed block.
      def record(*fields : String) : Nil
        record(fields)
      end

      # :ditto:
      def record(fields : Indexable(String)) : Nil
        commit { |b| b.record(fields) }
      end

      # Append an SOH header as a committed block.
      def header(*names : String) : Nil
        header(names)
      end

      # :ditto:
      def header(names : Indexable(String)) : Nil
        commit { |b| b.header(names) }
      end

      # Append a group preamble (GS + name) as a committed block.
      def group(name : String, headers : Indexable(String)? = nil) : Nil
        commit { |b| b.group(name, headers) }
      end

      # Append several records under a single commit. The batch is
      # atomic: a tear anywhere inside it discards the whole block.
      def batch(& : Builder ->) : Nil
        commit { |b| yield b }
      end

      def flush : Nil
        @io.flush
      end

      def close : Nil
        @io.close
      end

      private def commit(& : Builder ->) : Nil
        builder = Builder.new
        yield builder
        builder.etb
        @io.write(builder.to_slice)
        @io.flush
        if @sync && (io = @io).is_a?(File)
          io.fsync
        end
      end
    end
  end
end
