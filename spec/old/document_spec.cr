require "./spec_helper"

describe C0::Document do
  it "reads file name" do
    buf = C0::Builder.build do |b|
      b.file("mydb") do
        b.group("users") do
          b.record("Alice")
        end
      end
    end

    doc = C0::Document.new(buf)
    String.new(doc.name).should eq("mydb")
  end

  it "finds all top-level groups" do
    buf = C0::Builder.build do |b|
      b.file("mydb") do
        b.group("users") do
          b.record("Alice")
          b.record("Bob")
        end
        b.group("products") do
          b.record("Widget")
        end
        b.group("orders") do
          b.record("001")
        end
      end
    end

    doc = C0::Document.new(buf)
    doc.group_count.should eq(3)
    doc.group_names.map { |n| String.new(n) }.should eq(["users", "products", "orders"])
  end

  it "accesses groups by name" do
    buf = C0::Builder.build do |b|
      b.file("db") do
        b.group("users", headers: ["name", "amount"]) do
          b.record("Alice", "100")
          b.record("Bob", "200")
        end
        b.group("products", headers: ["id", "name"]) do
          b.record("01", "Widget")
        end
      end
    end

    doc = C0::Document.new(buf)

    users = doc["users"].table
    String.new(users.name).should eq("users")
    users.record_count.should eq(2)
    String.new(users.record(0).field(0)).should eq("Alice")
    String.new(users.record(1).field(1)).should eq("200")

    products = doc["products"].table
    products.record_count.should eq(1)
    String.new(products.record(0).field(1)).should eq("Widget")
  end

  it "accesses groups by index" do
    buf = C0::Builder.build do |b|
      b.file("db") do
        b.group("a") do
          b.record("1")
        end
        b.group("b") do
          b.record("2")
        end
      end
    end

    doc = C0::Document.new(buf)
    String.new(doc[0].name).should eq("a")
    String.new(doc[1].name).should eq("b")
  end

  it "raises on unknown group name" do
    buf = C0::Builder.build do |b|
      b.file("db") do
        b.group("users") do
          b.record("Alice")
        end
      end
    end

    doc = C0::Document.new(buf)
    expect_raises(KeyError) do
      doc["nonexistent"]
    end
  end

  it "handles document without FS" do
    buf = C0::Builder.build do |b|
      b.group("standalone") do
        b.record("data")
      end
    end

    doc = C0::Document.new(buf)
    doc.name.size.should eq(0)
    doc.group_count.should eq(1)
    String.new(doc[0].name).should eq("standalone")
  end

  it "handles key-value groups" do
    buf = C0::Builder.build do |b|
      b.group("config") do
        b.record("host", "localhost")
        b.record("port", "5432")
      end
    end

    doc = C0::Document.new(buf)
    config = doc["config"]
    config.has_header?.should eq(false)
    config.record_count.should eq(2)
    String.new(config.record(0).field(0)).should eq("host")
    String.new(config.record(0).field(1)).should eq("localhost")
  end

  it "handles groups with SOH headers" do
    buf = C0::Builder.build do |b|
      b.group("users", headers: ["name", "age"]) do
        b.record("Alice", "30")
      end
    end

    doc = C0::Document.new(buf)
    doc["users"].has_header?.should eq(true)
  end

  it "iterates groups" do
    buf = C0::Builder.build do |b|
      b.file("db") do
        b.group("a") do
          b.record("1")
        end
        b.group("b") do
          b.record("2")
        end
        b.group("c") do
          b.record("3")
        end
      end
    end

    doc = C0::Document.new(buf)
    names = [] of String
    doc.each_group { |g| names << String.new(g.name) }
    names.should eq(["a", "b", "c"])
  end

  it "handles document with EOT" do
    buf = C0::Builder.build do |b|
      b.file("db") do
        b.group("t") do
          b.record("x")
        end
      end
      b.eot
    end

    doc = C0::Document.new(buf)
    doc.group_count.should eq(1)
    String.new(doc[0].record(0).field(0)).should eq("x")
  end

  it "ignores deeper GS×N sections when counting top-level groups" do
    buf = C0::Builder.build do |b|
      b.file("doc") do
        b.section("Chapter 1") do
          b.block("Content.")
          b.section("Section 1.1", depth: 2) do
            b.block("Nested.")
          end
        end
        b.section("Chapter 2") do
          b.block("More.")
        end
      end
    end

    doc = C0::Document.new(buf)
    doc.group_count.should eq(2) # Only top-level chapters
    String.new(doc[0].name).should eq("Chapter 1")
    String.new(doc[1].name).should eq("Chapter 2")
  end
end
