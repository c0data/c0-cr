require "./spec_helper"

private def log_bytes(*parts : Bytes | UInt8 | String) : Bytes
  io = IO::Memory.new
  parts.each do |part|
    case part
    in Bytes  then io.write(part)
    in UInt8  then io.write_byte(part)
    in String then io << part
    end
  end
  io.to_slice
end

describe C0::Stream do
  describe "tokenizer" do
    it "emits ETB tokens" do
      buf = log_bytes(C0::RS, "create", C0::US, "a1b2", C0::ETB)
      types = C0::Tokenizer.new(buf).to_a.map(&.type)
      types.should eq([C0::TokenType::RS, C0::TokenType::Data,
                       C0::TokenType::US, C0::TokenType::Data,
                       C0::TokenType::ETB])
    end

    it "treats DLE-escaped ETB as data" do
      buf = log_bytes(C0::RS, C0::DLE, C0::ETB)
      tokens = C0::Tokenizer.new(buf).to_a
      tokens.map(&.type).should eq([C0::TokenType::RS, C0::TokenType::Data])
      tokens[1].value(buf).should eq(Bytes[C0::ETB])
    end
  end

  describe "table tolerance" do
    it "parses an ETB-committed log the same as an uncommitted one" do
      buf = log_bytes(
        Bytes[C0::GS], "claims", C0::ETB,
        Bytes[C0::SOH], "op", C0::US, "arg", C0::ETB,
        Bytes[C0::RS], "create", C0::US, "a1b2", C0::ETB,
        Bytes[C0::RS], "name", C0::US, "draft", C0::ETB,
      )
      t = C0::Table.new(buf)
      String.new(t.name).should eq("claims")
      t.headers.map { |h| String.new(h) }.should eq(["op", "arg"])
      t.record_count.should eq(2)
      t.record(0).fields.map { |f| String.new(f) }.should eq(["create", "a1b2"])
      t.record(1).fields.map { |f| String.new(f) }.should eq(["name", "draft"])
    end

    it "keeps ETB payload out of record bytes" do
      buf = log_bytes(Bytes[C0::RS], "a", C0::ETB, "payload",
        Bytes[C0::RS], "b", C0::ETB)
      t = C0::Table.new(buf)
      t.record_count.should eq(2)
      String.new(t.record(0).raw).should eq("a")
      String.new(t.record(1).raw).should eq("b")
    end
  end

  describe "pretty form" do
    it "renders ETB as ␗ on the record line and round-trips" do
      buf = log_bytes(Bytes[C0::RS], "create", C0::US, "a1b2", C0::ETB,
        Bytes[C0::RS], "name", C0::US, "draft", C0::ETB)
      pretty = C0::Pretty.format(buf)
      pretty.should contain("␞create␟a1b2␗")
      C0::Pretty.parse(pretty).should eq(buf)
    end
  end

  describe C0::Stream::Reader do
    it "reads committed records" do
      buf = log_bytes(Bytes[C0::RS], "create", C0::US, "a1b2", C0::ETB,
        Bytes[C0::RS], "name", C0::US, "draft", C0::ETB)
      r = C0::Stream::Reader.new(buf)
      r.torn?.should be_false
      r.block_count.should eq(2)
      records = [] of Array(String)
      r.each_record { |rec| records << rec.fields.map { |f| String.new(f) } }
      records.should eq([["create", "a1b2"], ["name", "draft"]])
    end

    it "skips a torn tail" do
      buf = log_bytes(Bytes[C0::RS], "create", C0::US, "a1b2", C0::ETB,
        Bytes[C0::RS], "name", C0::US, "dra") # tear: no ETB
      r = C0::Stream::Reader.new(buf)
      r.torn?.should be_true
      String.new(r.tail).should eq("\u{1E}name\u{1F}dra")
      r.table.record_count.should eq(1)
    end

    it "treats an empty buffer as clean" do
      r = C0::Stream::Reader.new(Bytes.empty)
      r.torn?.should be_false
      r.block_count.should eq(0)
    end

    it "discards a whole torn batch" do
      buf = log_bytes(Bytes[C0::RS], "a", C0::ETB,
        Bytes[C0::RS], "b", Bytes[C0::RS], "c") # batch of two, no commit
      r = C0::Stream::Reader.new(buf)
      r.torn?.should be_true
      r.table.record_count.should eq(1)
      String.new(r.block(0)).should eq("\u{1E}a")
    end

    it "commits a multi-record batch as one block" do
      buf = log_bytes(Bytes[C0::RS], "a", Bytes[C0::RS], "b", C0::ETB)
      r = C0::Stream::Reader.new(buf)
      r.block_count.should eq(1)
      r.table.record_count.should eq(2)
    end

    it "does not treat a DLE-escaped ETB as a commit" do
      buf = log_bytes(Bytes[C0::RS], "x", Bytes[C0::DLE, C0::ETB], "y")
      r = C0::Stream::Reader.new(buf)
      r.torn?.should be_true
      r.block_count.should eq(0)
    end

    it "does not treat an ETB inside an STX scope as a commit" do
      buf = log_bytes(Bytes[C0::RS], Bytes[C0::STX, C0::ETB, C0::ETX])
      r = C0::Stream::Reader.new(buf)
      r.torn?.should be_true
      r.block_count.should eq(0)
    end

    it "includes the ETB payload in the committed region but not the block" do
      buf = log_bytes(Bytes[C0::RS], "a", C0::ETB, "cafe")
      r = C0::Stream::Reader.new(buf)
      r.torn?.should be_false
      String.new(r.block(0)).should eq("\u{1E}a")
    end
  end

  describe C0::Stream::Writer do
    it "appends committed records to a file" do
      path = File.tempname("c0stream", ".c0")
      begin
        C0::Stream::Writer.open(path) do |log|
          log.header("op", "arg")
          log.record("create", "a1b2")
          log.record("name", "draft")
        end

        r = C0::Stream::Reader.read(path)
        r.torn?.should be_false
        r.block_count.should eq(3)
        t = r.table
        t.headers.map { |h| String.new(h) }.should eq(["op", "arg"])
        t.record_count.should eq(2)
      ensure
        File.delete?(path)
      end
    end

    it "escapes control bytes in field values" do
      path = File.tempname("c0stream", ".c0")
      begin
        C0::Stream::Writer.open(path) do |log|
          log.record("a\u{1E}b", "c\u{17}d")
        end
        r = C0::Stream::Reader.read(path)
        r.torn?.should be_false
        fields = r.table.record(0).fields.map { |f| String.new(f) }
        # Zero-copy slices retain the DLE escapes
        fields.should eq(["a\u{10}\u{1E}b", "c\u{10}\u{17}d"])
      ensure
        File.delete?(path)
      end
    end

    it "repairs a torn tail before appending" do
      path = File.tempname("c0stream", ".c0")
      begin
        C0::Stream::Writer.open(path, &.record("create", "a1b2"))
        # Simulate a crash mid-append
        File.open(path, "a", &.print("\u{1E}name\u{1F}dra"))
        C0::Stream::Reader.read(path).torn?.should be_true

        C0::Stream::Writer.open(path, &.record("tag", "alpha"))

        r = C0::Stream::Reader.read(path)
        r.torn?.should be_false
        records = [] of String
        r.each_record { |rec| records << String.new(rec.field(0)) }
        records.should eq(["create", "tag"])
      ensure
        File.delete?(path)
      end
    end

    it "repairs a tail torn mid-escape (bare trailing DLE)" do
      path = File.tempname("c0stream", ".c0")
      begin
        C0::Stream::Writer.open(path, &.record("create", "a1b2"))
        # Tear between DLE and its escaped byte — a blind append's RS
        # would be swallowed by this DLE
        File.open(path, "a", &.write(Bytes[C0::RS, 0x78, C0::DLE]))

        C0::Stream::Writer.open(path, &.record("tag", "alpha"))

        r = C0::Stream::Reader.read(path)
        r.torn?.should be_false
        r.table.record_count.should eq(2)
        String.new(r.table.record(1).field(0)).should eq("tag")
      ensure
        File.delete?(path)
      end
    end

    it "writes an atomic batch under one commit" do
      path = File.tempname("c0stream", ".c0")
      begin
        C0::Stream::Writer.open(path) do |log|
          log.batch do |b|
            b.record("name", "draft")
            b.record("tag", "alpha")
          end
        end
        r = C0::Stream::Reader.read(path)
        r.block_count.should eq(1)
        r.table.record_count.should eq(2)
      ensure
        File.delete?(path)
      end
    end
  end
end
