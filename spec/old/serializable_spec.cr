require "./spec_helper"

class User
  include C0::Serializable

  property name : String = ""
  property amount : String = ""

  def initialize(@name = "", @amount = "")
  end
end

class Product
  include C0::Serializable

  @[C0::Field(key: "product_id")]
  property id : Int32 = 0
  property name : String = ""
  property price : Float64 = 0.0
  property active : Bool = true

  def initialize(@id = 0, @name = "", @price = 0.0, @active = true)
  end
end

class WithOptional
  include C0::Serializable

  property name : String = ""
  property nickname : String? = nil

  def initialize(@name = "", @nickname = nil)
  end
end

class WithIgnored
  include C0::Serializable

  property name : String = ""

  @[C0::Field(ignore: true)]
  property internal : String = "secret"

  def initialize(@name = "", @internal = "secret")
  end
end

class WithArray
  include C0::Serializable

  property name : String = ""
  property tags : Array(String) = [] of String

  def initialize(@name = "", @tags = [] of String)
  end
end

describe C0::Serializable do
  describe "#to_c0 / .from_c0 round-trip" do
    it "serializes and deserializes a simple object" do
      user = User.new("Alice", "1502.30")
      buf = user.to_c0
      restored = User.from_c0(buf)
      restored.name.should eq("Alice")
      restored.amount.should eq("1502.30")
    end

    it "handles numeric and bool fields" do
      prod = Product.new(id: 42, name: "Widget", price: 9.99, active: true)
      buf = prod.to_c0
      restored = Product.from_c0(buf)
      restored.id.should eq(42)
      restored.name.should eq("Widget")
      restored.price.should eq(9.99)
      restored.active.should eq(true)
    end

    it "respects @[C0::Field(key:)] annotation" do
      prod = Product.new(id: 7, name: "Gadget", price: 19.99, active: false)
      buf = prod.to_c0

      # Verify the header uses "product_id" not "id"
      table = C0::Table.new(buf)
      String.new(table.header(0)).should eq("product_id")

      # Round-trip still works
      restored = Product.from_c0(buf)
      restored.id.should eq(7)
    end

    it "respects @[C0::Field(ignore:)] annotation" do
      obj = WithIgnored.new("Alice", "secret")
      buf = obj.to_c0

      table = C0::Table.new(buf)
      table.header_count.should eq(1)
      String.new(table.header(0)).should eq("name")

      restored = WithIgnored.from_c0(buf)
      restored.name.should eq("Alice")
      restored.internal.should eq("secret") # default value, not from C0
    end

    it "handles nilable fields" do
      obj = WithOptional.new("Bob", nil)
      buf = obj.to_c0
      restored = WithOptional.from_c0(buf)
      restored.name.should eq("Bob")
      restored.nickname.should be_nil

      obj = WithOptional.new("Bob", "Bobby")
      buf = obj.to_c0
      restored = WithOptional.from_c0(buf)
      restored.nickname.should eq("Bobby")
    end

    it "handles array fields" do
      obj = WithArray.new("Alice", ["admin", "editor"])
      buf = obj.to_c0
      restored = WithArray.from_c0(buf)
      restored.name.should eq("Alice")
      restored.tags.should eq(["admin", "editor"])
    end
  end

  describe "#to_c0_pretty" do
    it "returns pretty-printed string" do
      pretty = User.new("Alice", "100").to_c0_pretty
      pretty.should contain("␝")
      pretty.should contain("Alice")
    end
  end

  describe ".from_c0 with pretty string" do
    it "parses pretty-printed C0DATA" do
      pretty = "␝user\n  ␁name␟amount\n  ␞Alice␟100"
      user = User.from_c0(pretty)
      user.name.should eq("Alice")
      user.amount.should eq("100")
    end
  end

  describe "custom group name" do
    it "uses provided group name" do
      buf = User.new("Alice", "100").to_c0("people")
      table = C0::Table.new(buf)
      String.new(table.name).should eq("people")
    end

    it "defaults to downcased class name" do
      buf = User.new("Alice", "100").to_c0
      table = C0::Table.new(buf)
      String.new(table.name).should eq("user")
    end
  end

  describe "Array#to_c0" do
    it "serializes an array of objects as a multi-record group" do
      users = [User.new("Alice", "100"), User.new("Bob", "200")]
      buf = users.to_c0

      table = C0::Table.new(buf)
      String.new(table.name).should eq("user")
      table.header_count.should eq(2)
      table.record_count.should eq(2)
      String.new(table.record(0).field(0)).should eq("Alice")
      String.new(table.record(1).field(0)).should eq("Bob")

      # Round-trip via array_from_c0
      restored = User.array_from_c0(buf)
      restored.size.should eq(2)
      restored[0].name.should eq("Alice")
      restored[1].amount.should eq("200")
    end

    it "uses custom group name" do
      buf = [User.new("Alice", "100")].to_c0("people")
      table = C0::Table.new(buf)
      String.new(table.name).should eq("people")
    end
  end

  describe "Hash#to_c0" do
    it "serializes a hash as key-value group" do
      hash = {"host" => "localhost", "port" => "5432"}
      buf = hash.to_c0("database")

      table = C0::Table.new(buf)
      String.new(table.name).should eq("database")
      table.record_count.should eq(2)
      String.new(table.record(0).field(0)).should eq("host")
      String.new(table.record(0).field(1)).should eq("localhost")
    end
  end

  describe "NamedTuple#to_c0" do
    it "serializes a named tuple as key-value group" do
      tuple = {host: "localhost", port: "5432"}
      buf = tuple.to_c0("database")

      table = C0::Table.new(buf)
      String.new(table.name).should eq("database")
      table.record_count.should eq(2)
      String.new(table.record(0).field(0)).should eq("host")
      String.new(table.record(0).field(1)).should eq("localhost")
    end
  end

  describe "values with control codes" do
    it "round-trips strings containing control codes" do
      user = User.new("hello\x1eworld", "100")
      buf = user.to_c0
      restored = User.from_c0(buf)
      restored.name.should eq("hello\x1eworld")
    end
  end
end
