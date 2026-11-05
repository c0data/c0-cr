require "./spec_helper"

# Helper to build byte buffers with control codes.
# Accepts strings and UInt8 values, concatenates them.
def buf(*parts : String | UInt8) : Bytes
  io = IO::Memory.new
  parts.each do |part|
    case part
    when String then io.write(part.to_slice)
    when UInt8  then io.write_byte(part)
    end
  end
  io.to_slice
end

describe C0::Tokenizer do

  describe "data tokens" do
    it "emits a single data token for plain text" do
      b = buf("hello")
      tokens = C0::Tokenizer.new(b).to_a
      tokens.size.should eq(1)
      tokens[0].type.should eq(C0::TokenType::Data)
      String.new(tokens[0].value(b)).should eq("hello")
    end

    it "handles empty input" do
      b = Bytes.empty
      tokens = C0::Tokenizer.new(b).to_a
      tokens.size.should eq(0)
    end
  end

  describe "control codes" do
    it "emits FS token" do
      b = buf(C0::FS)
      tokens = C0::Tokenizer.new(b).to_a
      tokens.size.should eq(1)
      tokens[0].type.should eq(C0::TokenType::FS)
    end

    it "emits GS token" do
      b = buf(C0::GS)
      tokens = C0::Tokenizer.new(b).to_a
      tokens.size.should eq(1)
      tokens[0].type.should eq(C0::TokenType::GS)
    end

    it "emits RS token" do
      b = buf(C0::RS)
      tokens = C0::Tokenizer.new(b).to_a
      tokens.size.should eq(1)
      tokens[0].type.should eq(C0::TokenType::RS)
    end

    it "emits US token" do
      b = buf(C0::US)
      tokens = C0::Tokenizer.new(b).to_a
      tokens.size.should eq(1)
      tokens[0].type.should eq(C0::TokenType::US)
    end

    it "emits SOH token" do
      b = buf(C0::SOH)
      tokens = C0::Tokenizer.new(b).to_a
      tokens.size.should eq(1)
      tokens[0].type.should eq(C0::TokenType::SOH)
    end

    it "emits STX/ETX tokens" do
      b = buf(C0::STX, C0::ETX)
      tokens = C0::Tokenizer.new(b).to_a
      tokens.size.should eq(2)
      tokens[0].type.should eq(C0::TokenType::STX)
      tokens[1].type.should eq(C0::TokenType::ETX)
    end

    it "emits EOT token" do
      b = buf(C0::EOT)
      tokens = C0::Tokenizer.new(b).to_a
      tokens.size.should eq(1)
      tokens[0].type.should eq(C0::TokenType::EOT)
    end

    it "emits ENQ token" do
      b = buf(C0::ENQ)
      tokens = C0::Tokenizer.new(b).to_a
      tokens.size.should eq(1)
      tokens[0].type.should eq(C0::TokenType::ENQ)
    end

    it "emits SUB token" do
      b = buf(C0::SUB)
      tokens = C0::Tokenizer.new(b).to_a
      tokens.size.should eq(1)
      tokens[0].type.should eq(C0::TokenType::SUB)
    end
  end

  describe "tabular data" do
    it "tokenizes a simple table" do
      # [FS]mydb[GS]users[SOH]name[US]amount[RS]Alice[US]1502.30
      b = buf(
        C0::FS, "mydb",
        C0::GS, "users",
        C0::SOH, "name", C0::US, "amount",
        C0::RS, "Alice", C0::US, "1502.30"
      )
      tokens = C0::Tokenizer.new(b).to_a

      types = tokens.map(&.type)
      types.should eq([
        C0::TokenType::FS, C0::TokenType::Data,
        C0::TokenType::GS, C0::TokenType::Data,
        C0::TokenType::SOH, C0::TokenType::Data,
        C0::TokenType::US, C0::TokenType::Data,
        C0::TokenType::RS, C0::TokenType::Data,
        C0::TokenType::US, C0::TokenType::Data,
      ])

      data_tokens = tokens.select { |t| t.type == C0::TokenType::Data }
      values = data_tokens.map { |t| String.new(t.value(b)) }
      values.should eq(["mydb", "users", "name", "amount", "Alice", "1502.30"])
    end
  end

  describe "DLE escaping" do
    it "escapes a control code as data" do
      # The value contains a literal RS (0x1E)
      b = buf("hello", C0::DLE, C0::RS, "world")
      tokens = C0::Tokenizer.new(b).to_a
      tokens.size.should eq(3)
      tokens[0].type.should eq(C0::TokenType::Data)
      tokens[1].type.should eq(C0::TokenType::Data) # escaped byte
      tokens[2].type.should eq(C0::TokenType::Data)

      String.new(tokens[0].value(b)).should eq("hello")
      tokens[1].value(b)[0].should eq(C0::RS) # literal 0x1E
      String.new(tokens[2].value(b)).should eq("world")
    end

    it "escapes DLE itself" do
      b = buf(C0::DLE, C0::DLE)
      tokens = C0::Tokenizer.new(b).to_a
      tokens.size.should eq(1)
      tokens[0].type.should eq(C0::TokenType::Data)
      tokens[0].value(b)[0].should eq(C0::DLE)
    end

    it "raises on DLE at end of input" do
      b = buf(C0::DLE)
      expect_raises(C0::UnexpectedEndError) do
        C0::Tokenizer.new(b).to_a
      end
    end
  end

  describe "strict mode" do
    it "rejects unassigned control codes" do
      b = buf(0x07_u8) # BEL — unassigned
      expect_raises(C0::UnassignedCodeError) do
        C0::Tokenizer.new(b).to_a
      end
    end

    it "rejects NUL" do
      b = buf(0x00_u8)
      expect_raises(C0::UnassignedCodeError) do
        C0::Tokenizer.new(b).to_a
      end
    end

    it "allows DEL (0x7F) as data" do
      b = buf(0x7f_u8)
      tokens = C0::Tokenizer.new(b).to_a
      tokens.size.should eq(1)
      tokens[0].type.should eq(C0::TokenType::Data)
    end
  end

  describe "edge cases" do
    it "handles consecutive delimiters (empty fields)" do
      b = buf(C0::RS, C0::US, C0::US, C0::RS)
      tokens = C0::Tokenizer.new(b).to_a
      types = tokens.map(&.type)
      types.should eq([
        C0::TokenType::RS,
        C0::TokenType::US,
        C0::TokenType::US,
        C0::TokenType::RS,
      ])
    end

    it "handles data between every control code" do
      b = buf(C0::FS, "a", C0::GS, "b", C0::RS, "c", C0::US, "d")
      tokens = C0::Tokenizer.new(b).to_a
      tokens.size.should eq(8)
      data_tokens = tokens.select { |t| t.type == C0::TokenType::Data }
      values = data_tokens.map { |t| String.new(t.value(b)) }
      values.should eq(["a", "b", "c", "d"])
    end

    it "handles UTF-8 data" do
      b = buf(C0::RS, "日本語", C0::US, "emoji 🎉")
      tokens = C0::Tokenizer.new(b).to_a
      data_tokens = tokens.select { |t| t.type == C0::TokenType::Data }
      values = data_tokens.map { |t| String.new(t.value(b)) }
      values.should eq(["日本語", "emoji 🎉"])
    end

    it "handles multiple GS for depth" do
      b = buf(C0::GS, C0::GS, C0::GS, "deep")
      tokens = C0::Tokenizer.new(b).to_a
      types = tokens.map(&.type)
      types.should eq([
        C0::TokenType::GS,
        C0::TokenType::GS,
        C0::TokenType::GS,
        C0::TokenType::Data,
      ])
    end
  end
end
