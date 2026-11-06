require "./spec_helper"

private class User
  include C0::Serializable
  property name : String
  property roles : Array(String)
  @[C0::Field(key: "amt")]
  property amount : Float64
  property note : String?

  def initialize(@name, @roles, @amount, @note = nil)
  end
end

describe "pretty form" do
  it "round-trips a document with text, levels, keyed records and a heading" do
    buf = C0::Builder.build do |b|
      b.syn(shape: "tabular")
      b.file("db")
      b.group("users", ["name", "roles", "address", "bio"]) do
        b.record
        b.field("Alice")
        b.list(["Admin", "Editor"])
        b.level do
          b.record
          b.key("city", "Springfield")
          b.key("street", "1 Main")
        end
        b.field("  padded\nlines\t\x1eraw  ")
        b.record("Bob", "", "", "")
      end
      b.group("config")
      b.map({"port" => "5432", "host" => "localhost"})
      b.eot
    end
    pretty = C0::Pretty.format(buf)
    pretty.should contain("␖␁shape␟tabular\n")
    pretty.should contain("␁␞name␟roles␟address␟bio")
    pretty.should contain("␂  padded\nlines\t␞raw  ␃")
    C0::Pretty.parse(pretty).should eq(buf)
    C0.canonical?(C0::Pretty.parse(pretty)).should be_false # SYN/EOT framing
    C0::Pretty.parse(C0::Pretty.format(buf, mode: C0::Pretty::FormatMode::Spaced)).should eq(buf)
  end

  it "refuses glyph characters in data" do
    buf = C0::Builder.build { |b| b.record("has ␃ glyph") }
    expect_raises(C0::Pretty::GlyphInDataError) { C0::Pretty.format(buf) }
  end

  it "aligns table columns" do
    buf = C0::Builder.build do |b|
      b.group("t", ["a", "bb"])
      b.record("x", "1")
      b.record("longer", "22")
    end
    out = C0::Pretty.format(buf, mode: C0::Pretty::FormatMode::Aligned)
    out.lines[1].should eq("  ␁␞a     ␟bb")
    out.lines[2].should eq("  ␞x     ␟1")
  end
end

describe "JSON" do
  it "exports without guessing and imports back" do
    buf = C0::Builder.build do |b|
      b.group("users", ["name", "roles", "address"]) do
        b.record
        b.field("Alice")
        b.list(["Admin", "Editor"])
        b.level do
          b.record
          b.key("city", "Springfield")
          b.key("street", "1 Main")
        end
      end
      b.group("pairs")
      b.record("host", "localhost")
      b.record("port", "5432")
      b.group("config")
      b.map({"host" => "0.0.0.0"})
    end
    json = C0::JSON.to_json(buf)
    v = ::JSON.parse(json)
    v["users"][0]["roles"].as_a.map(&.as_s).should eq(["Admin", "Editor"])
    v["users"][0]["address"]["city"].as_s.should eq("Springfield")
    v["pairs"].as_a.map { |r| r.as_a.map(&.as_s) }.should eq([["host", "localhost"], ["port", "5432"]])
    v["config"]["host"].as_s.should eq("0.0.0.0")
    back = C0::JSON.from_json(json)
    C0::JSON.to_json(back).should eq(json)
    C0.canonical?(back).should be_true
  end

  it "imports a top-level object of scalars as a map, order kept" do
    buf = C0::JSON.from_json(%({"b": "2", "a": "1"}), "cfg")
    buf.should eq(C0::Pretty.parse("␝cfg␞␁b␟2␁a␟1"))
  end
end

describe "Document" do
  it "ends the heading at a dead record" do
    doc = C0::Document.new(C0::Pretty.parse("␖␁shape␟tabular␇␞dead␞live"))
    doc.heading.keys.size.should eq(1)
    doc.body.records.map { |r| String.new(r.value(0)) }.should eq(["live"])
  end

  it "keeps a dead keyed unit and a note in the heading" do
    doc = C0::Document.new(C0::Pretty.parse("␖␁shape␟tabular␇␁x␟y␇note␞live"))
    doc.heading.keys.size.should eq(1)
    doc.body.records.size.should eq(1)
  end

  it "warns on unknown shape and version" do
    doc = C0::Document.new(C0::Pretty.parse("␖␁shape␟weird␁version␟2␞a␄"))
    doc.warnings.should contain("unknown shape 'weird'")
    doc.warnings.should contain("unknown version '2'")
  end

  it "warns on EM without a blob table and on a blob in a later heading" do
    c = C0::Container.new(C0::Pretty.parse("␖␞a␄␖␁blob␟␐␁␞name␟offset␟length␞x␟0␟1␘␞b␄␙Z"))
    c.warnings.should contain("blob table in a later heading is ignored")
    c.warnings.should contain("EM with no blob table: the region is unaddressable")
  end
end

describe "Reference" do
  it "requires every path segment to be a name" do
    expect_raises(C0::SyntaxError) { C0::Reference.parse(C0::Pretty.parse("␅␂a␟ b␃")) }
    expect_raises(C0::SyntaxError) { C0::Reference.parse(C0::Pretty.parse("␅␂a␟b␊c␃")) }
    C0::Reference.parse(C0::Pretty.parse("␅␂a␟b c␃")).path.size.should eq(2)
  end
end

describe "Stream tail" do
  it "is not torn when only EM and a blob follow the last commit" do
    r = C0::Stream::Reader.new(C0::Pretty.parse("␞a␗␙raw bytes"))
    r.torn?.should be_false
    C0::Stream::Reader.new(C0::Pretty.parse("␞a␗␞b")).torn?.should be_true
  end
end

describe "Builder" do
  it "refuses an empty note" do
    expect_raises(ArgumentError) { C0::Builder.build { |b| b.record("a"); b.note("") } }
    expect_raises(ArgumentError) { C0::Builder.build { |b| b.record("a"); b.bel("") } }
  end

  it "spells primitives as the bytes read" do
    g = ->(buf : Bytes) { buf }
    g.call(C0::Builder.build { |b| b.fs("inv").gs("users").soh.rs("name").us("amount") }).should eq C0::Pretty.parse("␜inv␝users␁␞name␟amount")
    g.call(C0::Builder.build { |b| b.rs("Alice").us("1502.30") }).should eq C0::Pretty.parse("␞Alice␟1502.30")
    g.call(C0::Builder.build { |b| b.rs.soh("host").us("localhost").soh("port").us("5432") }).should eq C0::Pretty.parse("␞␁host␟localhost␁port␟5432")
    g.call(C0::Builder.build { |b| b.rs("cfg").us.dle.rs.soh("b").us("2").can }).should eq C0::Pretty.parse("␞cfg␟␐␞␁b␟2␘")
    g.call(C0::Builder.build { |b| b.bel("checked").rs("x") }).should eq C0::Pretty.parse("␇checked␞x")
    g.call(C0::Builder.build { |b| b.bel.gs("old").rs("1").gs("new").rs("2") }).should eq C0::Pretty.parse("␇␝old␞1␝new␞2")
    g.call(C0::Builder.build { |b| b.gs.gs("sub").rs.enq("users").us.enq("users", "1") }).should eq C0::Pretty.parse("␝␝sub␞␅users␟␅␂users␟1␃")
    g.call(C0::Builder.build { |b| b.syn.soh("version").us("1").rs("a").eot }).should eq C0::Pretty.parse("␖␁version␟1␞a␄")
  end

  it "mixes primitives with composed methods" do
    buf = C0::Builder.build do |b|
      b.rs("a")
      b.field("b")
      b.record
      b.us("c")
      b.gs("g")
      b.key("k", "v")
      b.group("h", ["h"])
      b.field("x")
    end
    buf.should eq C0::Pretty.parse("␞a␟b␞␟c␝g␞␁k␟v␝h␁␞h␞x")
    expect_raises(C0::Error) { C0::Builder.build { |b| b.can } }
    expect_raises(C0::Error) { C0::Builder.build { |b| b.rs.enq("a", "b", "c", "d") } }
  end

  it "writes the same bytes through either layer" do
    hi = C0::Builder.build do |b|
      b.syn(shape: "tabular")
      b.group("users", ["name", "amount"]) { b.record("Alice", "1502.30"); b.record("Bob", "3 40") }
      b.group("cfg")
      b.map({"host" => "localhost", "port" => "5432"})
      b.eot
    end
    lo = C0::Builder.build do |b|
      b.syn.soh("shape").us("tabular")
      b.gs("users").soh.rs("name").us("amount").rs("Alice").us("1502.30").rs("Bob").us("3 40")
      b.gs("cfg").rs.soh("host").us("localhost").soh("port").us("5432").eot
    end
    lo.should eq hi
    C0.canonical?(C0::Document.new(lo).body.raw).should be_true
  end
end

describe "Validator" do
  it "rejects BEL before a non-element code in a diff body instead of looping" do
    buf = C0::Pretty.parse("␖␁shape␟diff␜a␝␇␟x␚Y")
    expect_raises(C0::SyntaxError) { C0.validate(buf) }
  end

  it "finds a non-adjacent duplicate key" do
    C0.canonical?(C0::Pretty.parse("␞␁a␟1␁b␟2␁a␟3")).should be_false
    C0.canonical?(C0::Pretty.parse("␞␁a␟1␁b␟2␁c␟3")).should be_true
  end
end

describe "CSV" do
  it "writes a reference as its path and picks a named group" do
    buf = C0::Pretty.parse("␝a␞1␝links␁␞user␟tag␞␅␂users␟1␃␟␅tags")
    C0::CSV.to_csv(buf, "links").should eq("user,tag\nusers/1,tags\n")
  end

  it "refuses a nested level" do
    buf = C0::Pretty.parse("␞a␟␐␞x␘")
    expect_raises(C0::Error, /nested level/) { C0::CSV.to_csv(buf) }
  end

  it "round-trips" do
    csv = "name,amount\nAlice,100\nBob,\"a, b\"\n"
    buf = C0::CSV.from_csv(csv, "t")
    buf.should eq(C0::Pretty.parse("␝t␁␞name␟amount␞Alice␟100␞Bob␟a, b"))
    C0::CSV.to_csv(buf).should eq(csv)
  end
end

describe "Serializable" do
  it "writes a header row and reads back" do
    u = User.new("Alice", ["admin", "editor"], 1.5, " spaced ")
    bytes = u.to_c0
    C0::Pretty.format(bytes).should eq("␝user\n  ␁␞name␟roles␟amt␟note\n  ␞Alice␟␐\n    ␞admin␟editor\n  ␘␟1.5␟␂ spaced ␃\n")
    back = User.from_c0(bytes)
    back.name.should eq("Alice")
    back.roles.should eq(["admin", "editor"])
    back.amount.should eq(1.5)
    back.note.should eq(" spaced ")
    arr = [u, User.new("Bob", [] of String, 2.0)].to_c0
    User.array_from_c0(arr).map(&.name).should eq(["Alice", "Bob"])
    User.array_from_c0(arr)[1].roles.should eq([] of String)
  end

  it "maps a Hash to one keyed record, order kept" do
    {"b" => "2", "a" => "1"}.to_c0("cfg").should eq(C0::Pretty.parse("␝cfg␞␁b␟2␁a␟1"))
  end
end

describe "stream writer" do
  it "writes a log with heading, header row and commits, and repairs a torn tail" do
    path = File.tempname("c0log")
    begin
      C0::Stream::Writer.open(path) do |w|
        w.start
        w.header("op", "id")
        w.record("create", "a1")
      end
      File.open(path, "a") { |f| f.write("\x1eorphan".to_slice) }
      C0::Stream::Reader.read(path).torn?.should be_true
      C0::Stream::Writer.open(path) { |w| w.record("name", "x") }
      r = C0::Stream::Reader.read(path)
      r.torn?.should be_false
      r.block_count.should eq(4)
      r.document.heading.shape.should eq("stream")
      r.records.map { |rec| rec.values.map { |v| String.new(v) } }.should eq([["create", "a1"], ["name", "x"]])
      r.table.headers.map { |h| String.new(h) }.should eq(["op", "id"])
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end

describe "documents" do
  it "reads a container with a blob tail" do
    buf = C0::Builder.build do |b|
      b.syn
      b.heading_level("blob") do
        b.header("name", "offset", "length")
        b.record("img", "0", "3")
      end
      b.eot
      b.syn
      b.group("g")
      b.record("a")
      b.eot
      b.em("xyz".to_slice)
    end
    c = C0::Container.new(buf)
    c.documents.size.should eq(2)
    c.has_em?.should be_true
    c.blob("img").should eq("xyz".to_slice)
    c.documents[1].group("g").record(0).value(0).should eq("a".to_slice)
    c.documents[0].warnings.should be_empty
  end

  it "warns on a missing SYN and EOT" do
    d = C0::Document.new("\x1ea".to_slice)
    d.warnings.should eq(["no SYN at the start of the document", "no EOT at the end of the document"])
  end
end
