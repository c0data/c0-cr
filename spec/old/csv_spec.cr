require "./spec_helper"
require "../src/c0/csv"

describe C0::CSV do
  describe ".from_csv" do
    it "converts CSV with headers and rows to C0DATA" do
      csv = "name,amount\nAlice,100\nBob,200\n"
      buf = C0::CSV.from_csv(csv, group_name: "users")

      table = C0::Table.new(buf)
      String.new(table.name).should eq("users")
      table.header_count.should eq(2)
      String.new(table.header(0)).should eq("name")
      String.new(table.header(1)).should eq("amount")
      table.record_count.should eq(2)
      String.new(table.record(0).field(0)).should eq("Alice")
      String.new(table.record(0).field(1)).should eq("100")
      String.new(table.record(1).field(0)).should eq("Bob")
      String.new(table.record(1).field(1)).should eq("200")
    end

    it "uses default group name" do
      csv = "x\n1\n"
      buf = C0::CSV.from_csv(csv)
      table = C0::Table.new(buf)
      String.new(table.name).should eq("data")
    end

    it "handles empty CSV" do
      buf = C0::CSV.from_csv("")
      buf.size.should eq(0)
    end

    it "handles CSV with only headers" do
      csv = "a,b,c\n"
      buf = C0::CSV.from_csv(csv, group_name: "t")
      table = C0::Table.new(buf)
      table.header_count.should eq(3)
      table.record_count.should eq(0)
    end

    it "handles quoted CSV fields" do
      csv = %("hello, world",plain\n"line1\nline2",ok\n)
      buf = C0::CSV.from_csv(csv, group_name: "q")
      table = C0::Table.new(buf)
      String.new(table.header(0)).should eq("hello, world")
      String.new(table.header(1)).should eq("plain")
    end
  end

  describe ".to_csv" do
    it "converts C0DATA table to CSV" do
      buf = C0::Builder.build do |b|
        b.group("users", headers: ["name", "amount"]) do
          b.record("Alice", "100")
          b.record("Bob", "200")
        end
      end

      csv = C0::CSV.to_csv(buf)
      csv.should eq("name,amount\nAlice,100\nBob,200\n")
    end

    it "handles table without headers" do
      buf = C0::Builder.build do |b|
        b.group("data") do
          b.record("a", "b")
          b.record("c", "d")
        end
      end

      csv = C0::CSV.to_csv(buf)
      csv.should eq("a,b\nc,d\n")
    end

    it "handles FS-prefixed document" do
      buf = C0::Builder.build do |b|
        b.file("mydb") do
          b.group("users", headers: ["name"]) do
            b.record("Alice")
          end
        end
      end

      csv = C0::CSV.to_csv(buf)
      csv.should eq("name\nAlice\n")
    end

    it "quotes CSV fields containing commas" do
      buf = C0::Builder.build do |b|
        b.group("data", headers: ["val"]) do
          b.record("hello, world")
        end
      end

      csv = C0::CSV.to_csv(buf)
      csv.should contain(%("hello, world"))
    end
  end

  describe "round-trip" do
    it "csv-import then csv-export preserves data" do
      original = "name,score,grade\nAlice,95,A\nBob,87,B+\n"
      buf = C0::CSV.from_csv(original, group_name: "students")
      result = C0::CSV.to_csv(buf)
      result.should eq(original)
    end
  end
end
