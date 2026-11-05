require "./spec_helper"

describe C0::Pretty do
  describe ".format" do
    it "formats a simple table" do
      buf = C0::Builder.build do |b|
        b.group("users", headers: ["name", "amount", "type"]) do
          b.record("Alice", "1502.30", "DEPOSIT")
          b.record("Bob", "340.00", "WITHDRAWAL")
        end
      end

      out = C0::Pretty.format(buf)
      out.should contain("␝users")
      out.should contain("␁name␟amount␟type")
      out.should contain("␞Alice␟1502.30␟DEPOSIT")
      out.should contain("␞Bob␟340.00␟WITHDRAWAL")
    end

    it "formats a database with file and groups" do
      buf = C0::Builder.build do |b|
        b.file("mydb") do
          b.group("users", headers: ["name", "amount"]) do
            b.record("Alice", "1502.30")
          end
        end
        b.eot
      end

      out = C0::Pretty.format(buf)
      out.should contain("␜mydb")
      out.should contain("␝users")
      out.should contain("␁name␟amount")
      out.should contain("␞Alice␟1502.30")
      out.should contain("␄")
    end

    it "formats document-mode sections with depth" do
      buf = C0::Builder.build do |b|
        b.file("doc") do
          b.section("Chapter 1") do
            b.block("Content here.")
            b.section("Section 1.1", depth: 2) do
              b.block("Nested.")
            end
          end
        end
      end

      out = C0::Pretty.format(buf)
      out.should contain("␜doc")
      out.should contain("␝Chapter 1")
      out.should contain("␞Content here.")
      out.should contain("␝␝Section 1.1")
      out.should contain("␞Nested.")
    end

    it "formats key-value config" do
      buf = C0::Builder.build do |b|
        b.group("database") do
          b.record("host", "localhost")
          b.record("port", "5432")
        end
      end

      out = C0::Pretty.format(buf)
      out.should contain("␝database")
      out.should contain("␞host␟localhost")
      out.should contain("␞port␟5432")
    end
  end

  describe ".parse" do
    it "round-trips a table through format and parse" do
      original = C0::Builder.build do |b|
        b.group("users", headers: ["name", "amount"]) do
          b.record("Alice", "1502.30")
          b.record("Bob", "340.00")
        end
      end

      pretty = C0::Pretty.format(original)
      reparsed = C0::Pretty.parse(pretty)

      # Should produce identical compact bytes
      t = C0::Table.new(reparsed)
      String.new(t.name).should eq("users")
      t.header_count.should eq(2)
      t.record_count.should eq(2)
      String.new(t.record(0).field(0)).should eq("Alice")
      String.new(t.record(1).field(1)).should eq("340.00")
    end

    it "strips indentation whitespace" do
      pretty = "␜mydb\n  ␝users\n    ␁name␟amount\n    ␞Alice␟100\n"
      buf = C0::Pretty.parse(pretty)

      tokens = C0::Tokenizer.new(buf).to_a
      data = tokens.select { |t| t.type == C0::TokenType::Data }
      values = data.map { |t| String.new(t.value(buf)) }
      values.should eq(["mydb", "users", "name", "amount", "Alice", "100"])
    end

    it "trims whitespace adjacent to control codes" do
      pretty = "␞  Alice  ␟  1502.30  "
      buf = C0::Pretty.parse(pretty)

      tokens = C0::Tokenizer.new(buf).to_a
      data = tokens.select { |t| t.type == C0::TokenType::Data }
      values = data.map { |t| String.new(t.value(buf)) }
      values.should eq(["Alice", "1502.30"])
    end

    it "preserves whitespace inside STX/ETX (quoting)" do
      pretty = "␞␂  Alice  ␃␟␂  1502.30  ␃"
      buf = C0::Pretty.parse(pretty)

      tokens = C0::Tokenizer.new(buf).to_a
      data = tokens.select { |t| t.type == C0::TokenType::Data }
      values = data.map { |t| String.new(t.value(buf)) }
      values.should eq(["  Alice  ", "  1502.30  "])
    end

    it "preserves whitespace inside nested STX/ETX" do
      pretty = "␞␂ outer ␂ inner ␃ still outer ␃"
      buf = C0::Pretty.parse(pretty)

      # STX, " outer ", STX, " inner ", ETX, " still outer ", ETX
      tokens = C0::Tokenizer.new(buf).to_a
      stx_count = tokens.count { |t| t.type == C0::TokenType::STX }
      etx_count = tokens.count { |t| t.type == C0::TokenType::ETX }
      stx_count.should eq(2)
      etx_count.should eq(2)
    end

    it "preserves spaces between words without trimming" do
      pretty = "␞Alice Smith␟New York"
      buf = C0::Pretty.parse(pretty)

      tokens = C0::Tokenizer.new(buf).to_a
      data = tokens.select { |t| t.type == C0::TokenType::Data }
      values = data.map { |t| String.new(t.value(buf)) }
      values.should eq(["Alice Smith", "New York"])
    end
  end

  describe ".format with modes" do
    it "formats with spaced mode — columns aligned with spaces" do
      buf = C0::Builder.build do |b|
        b.group("users", headers: ["name", "age"]) do
          b.record("Alice", "30")
          b.record("Bob", "25")
        end
      end

      out = C0::Pretty.format(buf, mode: C0::Pretty::FormatMode::Spaced)
      out.should contain("␁ name  ␟ age")
      out.should contain("␞ Alice ␟ 30")
      out.should contain("␞ Bob   ␟ 25")
    end

    it "formats with aligned mode — columns aligned without extra spaces" do
      buf = C0::Builder.build do |b|
        b.group("users", headers: ["name", "age"]) do
          b.record("Alice", "30")
          b.record("Bob", "25")
        end
      end

      out = C0::Pretty.format(buf, mode: C0::Pretty::FormatMode::Aligned)
      out.should contain("␁name ␟age")
      out.should contain("␞Alice␟30")
      out.should contain("␞Bob  ␟25")
    end

    it "formats with compact mode — no padding" do
      buf = C0::Builder.build do |b|
        b.group("users", headers: ["name", "age"]) do
          b.record("Alice", "30")
        end
      end

      out = C0::Pretty.format(buf, mode: C0::Pretty::FormatMode::Compact)
      out.should contain("␁name␟age")
      out.should contain("␞Alice␟30")
    end

    it "align round-trips through parse" do
      buf = C0::Builder.build do |b|
        b.group("users", headers: ["name", "age"]) do
          b.record("Alice", "30")
          b.record("Bob", "25")
        end
      end

      spaced = C0::Pretty.format(buf, mode: C0::Pretty::FormatMode::Spaced)
      reparsed = C0::Pretty.parse(spaced)
      reparsed.should eq(buf)
    end

    it "align handles mixed table and non-table lines" do
      buf = C0::Builder.build do |b|
        b.file("mydb") do
          b.group("users", headers: ["name", "age"]) do
            b.record("Alice", "30")
          end
          b.group("config") do
            b.record("host", "localhost")
          end
        end
      end

      spaced = C0::Pretty.format(buf, mode: C0::Pretty::FormatMode::Spaced)
      spaced.should contain("␜ mydb")
      spaced.should contain("␝ users")
      spaced.should contain("␞ Alice ␟ 30")
    end
  end

  describe ".align" do
    it "standalone function works on pretty strings" do
      pretty = "␝users\n  ␁name␟age\n  ␞Alice␟30\n  ␞Bob␟25\n"
      spaced = C0::Pretty.align(pretty, C0::Pretty::FormatMode::Spaced)
      spaced.should contain("␁ name  ␟ age")
      spaced.should contain("␞ Alice ␟ 30")
      spaced.should contain("␞ Bob   ␟ 25")
    end
  end

  describe "glyph mapping" do
    it "maps all assigned codes to correct Unicode Control Pictures" do
      C0::Pretty.glyph(C0::SOH).should eq('␁')
      C0::Pretty.glyph(C0::STX).should eq('␂')
      C0::Pretty.glyph(C0::ETX).should eq('␃')
      C0::Pretty.glyph(C0::EOT).should eq('␄')
      C0::Pretty.glyph(C0::ENQ).should eq('␅')
      C0::Pretty.glyph(C0::DLE).should eq('␐')
      C0::Pretty.glyph(C0::SUB).should eq('␚')
      C0::Pretty.glyph(C0::FS).should eq('␜')
      C0::Pretty.glyph(C0::GS).should eq('␝')
      C0::Pretty.glyph(C0::RS).should eq('␞')
      C0::Pretty.glyph(C0::US).should eq('␟')
    end
  end
end
