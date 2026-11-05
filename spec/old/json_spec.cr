require "./spec_helper"
require "../src/c0/json"

describe C0::JSON do
  # --- Export ---

  describe ".to_json" do
    it "exports tabular group as array of objects" do
      buf = C0::Builder.build do |b|
        b.group("users", headers: ["name", "amount"]) do
          b.record("Alice", "100")
          b.record("Bob", "200")
        end
      end

      result = ::JSON.parse(C0::JSON.to_json(buf))
      result["users"].size.should eq(2)
      result["users"][0]["name"].as_s.should eq("Alice")
      result["users"][0]["amount"].as_s.should eq("100")
      result["users"][1]["name"].as_s.should eq("Bob")
    end

    it "exports key-value group as flat object" do
      buf = C0::Builder.build do |b|
        b.group("database") do
          b.record("host", "localhost")
          b.record("port", "5432")
        end
      end

      result = ::JSON.parse(C0::JSON.to_json(buf))
      result["database"]["host"].as_s.should eq("localhost")
      result["database"]["port"].as_s.should eq("5432")
    end

    it "exports multi-field records without headers as array of arrays" do
      buf = C0::Builder.build do |b|
        b.group("data") do
          b.record("a", "b", "c")
          b.record("d", "e", "f")
        end
      end

      result = ::JSON.parse(C0::JSON.to_json(buf))
      result["data"][0][0].as_s.should eq("a")
      result["data"][0][2].as_s.should eq("c")
      result["data"][1][1].as_s.should eq("e")
    end

    it "exports full document with multiple groups" do
      buf = C0::Builder.build do |b|
        b.file("mydb") do
          b.group("users", headers: ["name"]) do
            b.record("Alice")
          end
          b.group("config") do
            b.record("host", "localhost")
          end
        end
      end

      result = ::JSON.parse(C0::JSON.to_json(buf))
      result["mydb"]["users"][0]["name"].as_s.should eq("Alice")
      result["mydb"]["config"]["host"].as_s.should eq("localhost")
    end

    it "handles DLE-escaped field values" do
      buf = C0::Builder.build do |b|
        b.group("data", headers: ["val"]) do
          b.record("hello\x1fworld")
        end
      end

      result = ::JSON.parse(C0::JSON.to_json(buf))
      result["data"][0]["val"].as_s.should eq("hello\x1fworld")
    end

    it "handles empty group" do
      buf = C0::Builder.build do |b|
        b.group("empty") {}
      end

      result = ::JSON.parse(C0::JSON.to_json(buf))
      result["empty"].as_a.size.should eq(0)
    end
  end

  describe ".to_yaml" do
    it "exports tabular group as YAML" do
      buf = C0::Builder.build do |b|
        b.group("users", headers: ["name", "amount"]) do
          b.record("Alice", "100")
          b.record("Bob", "200")
        end
      end

      result = ::YAML.parse(C0::JSON.to_yaml(buf))
      result["users"][0]["name"].as_s.should eq("Alice")
      result["users"][0]["amount"].as_s.should eq("100")
    end

    it "exports key-value group as YAML" do
      buf = C0::Builder.build do |b|
        b.group("config") do
          b.record("host", "0.0.0.0")
          b.record("port", "8080")
        end
      end

      result = ::YAML.parse(C0::JSON.to_yaml(buf))
      result["config"]["host"].as_s.should eq("0.0.0.0")
      result["config"]["port"].as_s.should eq("8080")
    end

    it "exports full document as YAML" do
      buf = C0::Builder.build do |b|
        b.file("app") do
          b.group("settings") do
            b.record("debug", "true")
          end
        end
      end

      result = ::YAML.parse(C0::JSON.to_yaml(buf))
      result["app"]["settings"]["debug"].as_s.should eq("true")
    end
  end

  # --- Import ---

  describe ".from_json" do
    it "imports flat key-value object as KV group" do
      json = %|{"host": "localhost", "port": "5432"}|
      buf = C0::JSON.from_json(json, group_name: "config")

      table = C0::Table.new(buf)
      String.new(table.name).should eq("config")
      table.record_count.should eq(2)
      String.new(table.record(0).field(0)).should eq("host")
      String.new(table.record(0).field(1)).should eq("localhost")
      String.new(table.record(1).field(0)).should eq("port")
      String.new(table.record(1).field(1)).should eq("5432")
    end

    it "imports array of objects as table with headers" do
      json = %|{"users": [{"name": "Alice", "age": "30"}, {"name": "Bob", "age": "25"}]}|
      buf = C0::JSON.from_json(json)

      table = C0::Table.new(buf)
      String.new(table.name).should eq("users")
      table.header_count.should eq(2)
      String.new(table.header(0)).should eq("name")
      String.new(table.header(1)).should eq("age")
      table.record_count.should eq(2)
      String.new(table.record(0).field(0)).should eq("Alice")
      String.new(table.record(1).field(1)).should eq("25")
    end

    it "imports wrapped document with FS" do
      json = %|{"mydb": {"users": [{"name": "Alice"}], "config": {"host": "localhost", "port": "5432"}}}|
      buf = C0::JSON.from_json(json)

      doc = C0::Document.new(buf)
      String.new(doc.name).should eq("mydb")
      doc.group_count.should eq(2)

      users = doc.group("users").table
      String.new(users.header(0)).should eq("name")
      String.new(users.record(0).field(0)).should eq("Alice")

      config = doc.group("config").table
      String.new(config.record(0).field(0)).should eq("host")
      String.new(config.record(0).field(1)).should eq("localhost")
    end

    it "imports multiple groups without FS wrapper" do
      json = %|{"users": [{"name": "Alice"}], "products": [{"id": "1"}]}|
      buf = C0::JSON.from_json(json)

      # Should have two GS groups (no FS)
      tok = C0::Tokenizer.new(buf)
      types = tok.to_a.map(&.type)
      types.count(C0::TokenType::GS).should eq(2)
      types.count(C0::TokenType::FS).should eq(0)
    end

    it "imports numeric and boolean values as strings" do
      json = %|{"count": 42, "active": true, "rate": 3.14}|
      buf = C0::JSON.from_json(json, group_name: "data")

      table = C0::Table.new(buf)
      String.new(table.record(0).field(1)).should eq("42")
      String.new(table.record(1).field(1)).should eq("true")
      String.new(table.record(2).field(1)).should eq("3.14")
    end

    it "imports nested object values with STX/ETX" do
      json = %|{"user": {"name": "Alice", "address": {"city": "Portland", "state": "OR"}}}|
      buf = C0::JSON.from_json(json)

      # The group "user" should have records including nested address
      table = C0::Table.new(buf)
      String.new(table.name).should eq("user")
      table.record_count.should eq(2)
      String.new(table.record(0).field(0)).should eq("name")
      String.new(table.record(0).field(1)).should eq("Alice")
      # address field should have 2 fields (key + nested value with STX/ETX)
      String.new(table.record(1).field(0)).should eq("address")
      addr_field = table.record(1).field(1)
      addr_field[0].should eq(C0::STX)
    end

    it "imports array values with STX/ETX" do
      json = %|{"tags": ["alpha", "beta", "gamma"]}|
      buf = C0::JSON.from_json(json)

      table = C0::Table.new(buf)
      String.new(table.name).should eq("tags")
      # Array of strings → records
      table.record_count.should eq(3)
      String.new(table.record(0).field(0)).should eq("alpha")
      String.new(table.record(2).field(0)).should eq("gamma")
    end
  end

  describe ".from_yaml" do
    it "imports YAML key-value as KV group" do
      yaml = "host: localhost\nport: \"5432\"\n"
      buf = C0::JSON.from_yaml(yaml, group_name: "config")

      table = C0::Table.new(buf)
      String.new(table.name).should eq("config")
      String.new(table.record(0).field(0)).should eq("host")
      String.new(table.record(0).field(1)).should eq("localhost")
    end

    it "imports YAML array of objects as table" do
      yaml = "---\nusers:\n- name: Alice\n  age: \"30\"\n- name: Bob\n  age: \"25\"\n"
      buf = C0::JSON.from_yaml(yaml)

      table = C0::Table.new(buf)
      String.new(table.name).should eq("users")
      table.header_count.should eq(2)
      String.new(table.record(0).field(0)).should eq("Alice")
    end
  end

  # --- Round-trips ---

  describe "round-trip" do
    it "JSON → C0DATA → JSON preserves flat table" do
      original = %|{"users": [{"name": "Alice", "score": "95"}, {"name": "Bob", "score": "87"}]}|
      buf = C0::JSON.from_json(original)
      result = ::JSON.parse(C0::JSON.to_json(buf))
      expected = ::JSON.parse(original)
      result.should eq(expected)
    end

    it "JSON → C0DATA → JSON preserves key-value" do
      original = %|{"host": "localhost", "port": "5432"}|
      buf = C0::JSON.from_json(original, group_name: "config")
      result = ::JSON.parse(C0::JSON.to_json(buf))
      expected = ::JSON.parse(%|{"config": {"host": "localhost", "port": "5432"}}|)
      result.should eq(expected)
    end

    it "JSON → C0DATA → JSON preserves document with multiple groups" do
      original = %|{"mydb": {"users": [{"name": "Alice"}], "settings": {"debug": "true", "port": "8080"}}}|
      buf = C0::JSON.from_json(original)
      result = ::JSON.parse(C0::JSON.to_json(buf))
      expected = ::JSON.parse(original)
      result.should eq(expected)
    end

    it "JSON → C0DATA → JSON preserves nested objects" do
      original = %|{"config": {"db": {"host": "localhost", "port": "5432"}, "name": "myapp"}}|
      buf = C0::JSON.from_json(original)
      result = ::JSON.parse(C0::JSON.to_json(buf))
      expected = ::JSON.parse(original)
      result.should eq(expected)
    end
  end
end
