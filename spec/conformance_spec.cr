require "./spec_helper"
require "json"

# Runs the shared conformance vectors from the c0-spec submodule
# (https://github.com/c0data/c0-spec), the source of truth. These fixtures
# are the normative companion to the spec's "Canonical Form" section;
# every implementation (c0-js, c0-rs, c0-c, …) consumes the same files.

CONFORMANCE_DIR = File.join(__DIR__, "..", "c0-spec", "vectors")

private def conformance_cases(file : String) : Array(::JSON::Any)
  ::JSON.parse(File.read(File.join(CONFORMANCE_DIR, file)))["cases"].as_a
end

# A field is a JSON string (UTF-8 bytes) or {"hex": "..."} (raw bytes).
private def field_bytes(f : ::JSON::Any) : Bytes
  if s = f.as_s?
    s.to_slice
  else
    f["hex"].as_s.hexbytes
  end
end

private def check_table(t : C0::Table, g : ::JSON::Any) : Nil
  String.new(t.name).should eq(g["name"].as_s)
  if headers = g["headers"].as_a?
    t.headers.map { |h| String.new(h) }.should eq(headers.map(&.as_s))
  else
    t.header_count.should eq(0)
  end
  records = g["records"].as_a
  t.record_count.should eq(records.size)
  records.each_with_index do |r, i|
    rec = t.record(i)
    expected = r.as_a
    rec.field_count.should eq(expected.size)
    expected.each_with_index do |f, j|
      rec.value(j).should eq(field_bytes(f))
    end
  end
end

describe "conformance" do
  describe "decode.json" do
    conformance_cases("decode.json").each do |c|
      it c["name"].as_s do
        bytes = c["bytes"].as_s.hexbytes
        file_name = c["file"].as_s?
        groups = c["groups"].as_a

        if file_name.nil? && groups.size == 1 && groups[0]["name"].as_s.empty?
          check_table(C0::Table.new(bytes), groups[0])
        else
          doc = C0::Document.new(bytes)
          String.new(doc.name).should eq(file_name || "")
          doc.group_count.should eq(groups.size)
          groups.each_with_index do |g, i|
            check_table(doc.group(i).table, g)
          end
        end
      end
    end
  end

  describe "encode.json" do
    conformance_cases("encode.json").each do |c|
      it c["name"].as_s do
        build = c["build"]
        groups = build["groups"].as_a

        emit_groups = ->(b : C0::Builder) do
          groups.each do |g|
            headers = g["headers"].as_a?.try(&.map(&.as_s))
            b.group(g["name"].as_s, headers: headers)
            g["records"].as_a.each do |r|
              b.record(r.as_a.map { |f| String.new(field_bytes(f)) })
            end
          end
        end

        buf = C0::Builder.build do |b|
          if file_name = build["file"].as_s?
            b.file(file_name) { emit_groups.call(b) }
          else
            emit_groups.call(b)
          end
        end

        buf.hexstring.should eq(c["canonical"].as_s)
        C0.canonical?(buf).should be_true
      end
    end
  end

  describe "canonical.json" do
    conformance_cases("canonical.json").each do |c|
      it c["name"].as_s do
        bytes = c["bytes"].as_s.hexbytes

        wellformed = begin
          C0::Tokenizer.new(bytes).each { }
          true
        rescue C0::Error
          false
        end
        wellformed.should eq(c["wellformed"].as_bool)

        C0.canonical?(bytes).should eq(c["canonical"].as_bool)
      end
    end
  end

  describe "invalid.json" do
    conformance_cases("invalid.json").each do |c|
      it c["name"].as_s do
        bytes = c["bytes"].as_s.hexbytes
        expect_raises(C0::Error) do
          C0::Tokenizer.new(bytes).each { }
        end
      end
    end
  end

  describe "stream.json" do
    conformance_cases("stream.json").each do |c|
      it c["name"].as_s do
        bytes = c["bytes"].as_s.hexbytes
        reader = C0::Stream::Reader.new(bytes)

        reader.committed_end.should eq(c["committed_end"].as_i)
        reader.torn?.should eq(c["torn"].as_bool)

        expected_blocks = c["blocks"].as_a.map(&.as_s)
        reader.block_count.should eq(expected_blocks.size)
        expected_blocks.each_with_index do |hex, i|
          reader.block(i).hexstring.should eq(hex)
        end

        if records = c["records"]?
          t = reader.table
          expected = records.as_a
          t.record_count.should eq(expected.size)
          expected.each_with_index do |r, i|
            t.record(i).values.map { |v| String.new(v) }.should eq(r.as_a.map(&.as_s))
          end
        end
      end
    end
  end
end
