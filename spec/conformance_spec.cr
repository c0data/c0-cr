require "./spec_helper"
require "json"

# Runs the shared conformance vectors from the c0-spec submodule
# (https://github.com/c0data/c0-spec), the source of truth. Schema v2:
# see c0-spec/vectors/README.md.

CONFORMANCE_DIR = File.join(__DIR__, "..", "c0-spec", "vectors")

private def conformance_cases(file : String) : Array(::JSON::Any)
  ::JSON.parse(File.read(File.join(CONFORMANCE_DIR, file)))["cases"].as_a
end

# A scalar expected value: JSON string or {"hex": ...}.
private def scalar_bytes(f : ::JSON::Any) : Bytes
  if s = f.as_s?
    s.to_slice
  else
    f["hex"].as_s.hexbytes
  end
end

private def scalar?(f : ::JSON::Any) : Bool
  !f.as_s?.nil? || (f.as_h? && f["hex"]?) ? true : false
end

# Flatten a group list with "sections" into (depth, group) pairs.
private def flat_groups(groups : Array(::JSON::Any), depth : Int32 = 1) : Array({Int32, ::JSON::Any})
  out = Array({Int32, ::JSON::Any}).new
  groups.each do |g|
    d = g["name"].as_s.empty? && depth == 1 && g["headers"]?.try(&.raw).nil? && false ? 0 : depth
    out << {depth, g}
    if secs = g["sections"]?
      out.concat(flat_groups(secs.as_a, depth + 1))
    end
  end
  out
end

private def check_value(rec : C0::Record, i : Int32, f : ::JSON::Any) : Nil
  if scalar?(f)
    rec.value(i).should eq(scalar_bytes(f))
  elsif lvl = f["level"]?
    check_body(rec.level(i), lvl)
  elsif ref = f["ref"]?
    r = rec.ref(i)
    if s = ref.as_s?
      r.path.should eq([s.to_slice])
    else
      r.path.should eq(ref.as_a.map { |x| x.as_s.to_slice })
    end
  else
    raise "unknown value form #{f}"
  end
end

private def check_record(rec : C0::Record, r : ::JSON::Any) : Nil
  if arr = r.as_a?
    rec.keyed?.should be_false
    rec.field_count.should eq(arr.size)
    arr.each_with_index { |f, j| check_value(rec, j, f) }
  else
    rec.keyed?.should be_true
    pairs = r["keys"].as_a
    rec.keys.map { |k| String.new(k) }.should eq(pairs.map { |p| p[0].as_s })
    got = rec.pairs
    pairs.each_with_index do |p, j|
      got[j][1].should eq(scalar_bytes(p[1]))
    end
  end
end

private def check_group(g : C0::Group, e : ::JSON::Any) : Nil
  String.new(g.name).should eq(e["name"].as_s)
  if headers = e["headers"].as_a?
    g.headers.map { |h| String.new(h) }.should eq(headers.map(&.as_s))
  else
    g.has_header?.should be_false
  end
  records = e["records"].as_a
  g.record_count.should eq(records.size)
  records.each_with_index { |r, i| check_record(g.record(i), r) }
end

private def check_groups(groups : Array(C0::Group), expected : Array(::JSON::Any)) : Nil
  flat = flat_groups(expected)
  # the unnamed leading group has depth 0 in the reader
  groups.size.should eq(flat.size)
  flat.each_with_index do |(depth, e), i|
    g = groups[i]
    check_group(g, e)
    unless e["name"].as_s.empty? && i == 0
      g.depth.should eq(depth)
    end
  end
end

private def check_body(body : C0::Body, e : ::JSON::Any) : Nil
  if files = e["files"]?
    check_files(body, files.as_a)
  else
    groups = e["records"]? ? [e] : e["groups"].as_a
    if e["records"]?
      # a level described as a single table
      body.files.size.should eq(1)
      gs = body.files[0].groups
      if e["records"].as_a.empty? && e["headers"]?.try(&.as_a?).nil?
        gs.size.should eq(0)
      else
        gs.size.should eq(1)
        check_group(gs[0], ::JSON::Any.new({"name" => ::JSON::Any.new(""), "headers" => e["headers"], "records" => e["records"]}))
      end
    else
      check_groups(body.groups, groups)
    end
  end
end

private def check_files(body : C0::Body, files : Array(::JSON::Any)) : Nil
  body.files.size.should eq(files.size)
  files.each_with_index do |f, i|
    String.new(body.files[i].name).should eq(f["name"].as_s)
    check_groups(body.files[i].groups, f["groups"].as_a)
  end
end

private def check_heading(h : C0::Heading, e : ::JSON::Any) : Nil
  pairs = e.as_a
  h.keys.map { |k| String.new(k) }.should eq(pairs.map { |p| p[0].as_s })
  pairs.each_with_index do |p, i|
    v = p[1]
    if scalar?(v)
      h.pairs[i][1].should eq(scalar_bytes(v))
    elsif lvl = v["level"]?
      raw = h.pairs[i][1]
      body = C0::Body.new(raw, 1, C0::Scan.level(raw, 0) - 1)
      check_body(body, lvl)
    end
  end
end

# ---------------------------------------------------------------- building

private def build_value(b : C0::Builder, f : ::JSON::Any) : Nil
  if scalar?(f)
    b.field(scalar_bytes(f))
  elsif lvl = f["level"]?
    b.level { build_body(b, lvl) }
  elsif ref = f["ref"]?
    if s = ref.as_s?
      b.ref(s)
    else
      segs = ref.as_a.map(&.as_s)
      case segs.size
      when 1 then b.ref(segs[0])
      when 2 then b.ref(segs[0], segs[1])
      else        b.ref(segs[0], segs[1], segs[2])
      end
    end
  elsif m = f["map"]?
    b.level { build_record(b, ::JSON::Any.new({"keys" => m})) }
  else
    raise "unknown value form #{f}"
  end
end

private def build_record(b : C0::Builder, r : ::JSON::Any) : Nil
  if arr = r.as_a?
    b.record
    arr.each { |f| build_value(b, f) }
  else
    b.record
    pairs = r["keys"].as_a.sort_by { |p| p[0].as_s.to_slice.to_a }
    pairs.each do |p|
      v = p[1]
      if scalar?(v)
        b.key(p[0].as_s, scalar_bytes(v))
      elsif m = v["map"]?
        b.key(p[0].as_s) { build_record(b, ::JSON::Any.new({"keys" => m})) }
      elsif lvl = v["level"]?
        b.key(p[0].as_s) { build_body(b, lvl) }
      end
    end
  end
end

private def build_groups(b : C0::Builder, groups : Array(::JSON::Any)) : Nil
  groups.each_with_index do |g, i|
    headers = g["headers"].as_a?.try(&.map(&.as_s))
    if g["name"].as_s.empty? && i == 0
      b.header(headers) if headers # the unnamed leading group: no GS
    else
      b.group(g["name"].as_s, headers)
    end
    g["records"].as_a.each { |r| build_record(b, r) }
  end
end

private def build_body(b : C0::Builder, e : ::JSON::Any) : Nil
  if e["records"]?
    b.header(e["headers"].as_a.map(&.as_s)) if e["headers"]?.try(&.as_a?)
    e["records"].as_a.each { |r| build_record(b, r) }
  elsif e["groups"]?
    build_groups(b, e["groups"].as_a)
  end
end

# ================================================================== specs

describe "conformance" do
  describe "decode.json" do
    conformance_cases("decode.json").each do |c|
      it c["name"].as_s do
        bytes = c["bytes"].as_s.hexbytes
        if docs = c["documents"]?
          cont = C0::Container.new(bytes)
          cont.documents.size.should eq(docs.as_a.size)
          docs.as_a.each_with_index do |d, i|
            doc = cont.documents[i]
            check_heading(doc.heading, d["heading"]) if d["heading"]?
            String.new(doc.name).should eq(d["file"].as_s? || "")
            check_groups(doc.groups, d["groups"].as_a)
          end
        else
          cont = C0::Container.new(bytes)
          doc = cont.first
          if h = c["heading"]?
            doc.has_syn?.should be_true
            check_heading(doc.heading, h)
          end
          if files = c["files"]?
            check_files(doc.body, files.as_a)
          else
            String.new(doc.name).should eq(c["file"].as_s? || "")
            check_groups(doc.groups, c["groups"].as_a)
          end
          if tail = c["tail"]?
            cont.has_em?.should be_true
            cont.tail.hexstring.should eq(tail.as_s)
          end
        end
      end
    end
  end

  describe "encode.json" do
    conformance_cases("encode.json").each do |c|
      it c["name"].as_s do
        build = c["build"]
        emit = ->(b : C0::Builder) do
          if file_name = build["file"].as_s?
            b.file(file_name)
          end
          build_groups(b, build["groups"].as_a)
        end
        canonical = C0::Builder.build { |b| emit.call(b) }
        canonical.hexstring.should eq(c["canonical"].as_s)
        C0.canonical?(canonical).should be_true
        if h = build["heading"]?
          whole = C0::Builder.build do |b|
            pairs = {} of String => String
            h.as_a.each { |p| pairs[p[0].as_s] = p[1].as_s }
            b.syn(pairs)
            emit.call(b)
            b.eot
          end
          whole.hexstring.should eq(c["bytes"].as_s)
        end
      end
    end
  end

  describe "canonical.json" do
    conformance_cases("canonical.json").each do |c|
      it c["name"].as_s do
        bytes = c["bytes"].as_s.hexbytes
        wellformed = begin
          C0.validate(bytes)
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
        expect_raises(C0::Error) { C0.validate(bytes) }
      end
    end
  end

  describe "nested.json" do
    conformance_cases("nested.json").each do |c|
      it c["name"].as_s do
        bytes = c["bytes"].as_s.hexbytes
        expected = c["record"].as_a
        rec = C0::Body.new(bytes).record(0)
        rec.field_count.should eq(expected.size)
        expected.each_with_index do |f, i|
          if scalar?(f)
            rec.value(i).should eq(scalar_bytes(f))
          elsif items = f["list"]?
            if items.as_a.all? { |x| scalar?(x) }
              rec.list(i).should eq(items.as_a.map { |x| scalar_bytes(x) })
            else
              inner = rec.level(i).record(0)
              inner.field_count.should eq(items.as_a.size)
              items.as_a.each_with_index do |x, j|
                if scalar?(x)
                  inner.value(j).should eq(scalar_bytes(x))
                else
                  inner.list(j).should eq(x["list"].as_a.map { |y| scalar_bytes(y) })
                end
              end
            end
          elsif lvl = f["level"]?
            check_body(rec.level(i), lvl)
          end
        end
        if c["canonical"].as_bool
          buf = C0::Builder.build do |b|
            b.record
            expected.each do |f|
              if !scalar?(f) && (items = f["list"]?) && items.as_a.all? { |x| scalar?(x) }
                b.list(items.as_a.map { |x| String.new(scalar_bytes(x)) })
              elsif !scalar?(f) && (items = f["list"]?)
                b.level do
                  b.record
                  items.as_a.each do |x|
                    if scalar?(x)
                      b.field(scalar_bytes(x))
                    else
                      b.list(x["list"].as_a.map { |y| String.new(scalar_bytes(y)) })
                    end
                  end
                end
              else
                build_value(b, f)
              end
            end
          end
          buf.hexstring.should eq(c["bytes"].as_s)
          C0.canonical?(buf).should be_true
        end
      end
    end
  end

  describe "map-canonical.json" do
    conformance_cases("map-canonical.json").each do |c|
      it c["name"].as_s do
        buf = C0::Builder.build do |b|
          if g = c["group"].as_s?
            b.group(g)
          end
          build_record(b, ::JSON::Any.new({"keys" => c["map"]}))
        end
        buf.hexstring.should eq(c["canonical"].as_s)
        C0.canonical?(buf).should be_true
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
        expected_blocks.each_with_index { |hex, i| reader.block(i).hexstring.should eq(hex) }
        reader.damaged.should eq((c["damaged"]?.try(&.as_a.map(&.as_i))) || [] of Int32)
        if records = c["records"]?
          got = reader.records
          expected = records.as_a
          got.size.should eq(expected.size)
          expected.each_with_index do |r, i|
            got[i].values.map { |v| String.new(v) }.should eq(r.as_a.map(&.as_s))
          end
        end
      end
    end
  end
end
