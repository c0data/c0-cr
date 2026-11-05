require "./spec_helper"

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

describe C0::Table do
  it "reads group name" do
    b = buf(C0::GS, "users", C0::RS, "Alice")
    t = C0::Table.new(b)
    String.new(t.name).should eq("users")
  end

  it "reads SOH headers" do
    b = buf(C0::GS, "users", C0::SOH, "name", C0::US, "amount", C0::RS, "Alice", C0::US, "1502.30")
    t = C0::Table.new(b)
    t.header_count.should eq(2)
    String.new(t.header(0)).should eq("name")
    String.new(t.header(1)).should eq("amount")
  end

  it "reads records and fields" do
    b = buf(
      C0::GS, "users",
      C0::SOH, "name", C0::US, "amount", C0::US, "type",
      C0::RS, "Alice", C0::US, "1502.30", C0::US, "DEPOSIT",
      C0::RS, "Bob", C0::US, "340.00", C0::US, "WITHDRAWAL"
    )
    t = C0::Table.new(b)

    t.record_count.should eq(2)

    String.new(t.record(0).field(0)).should eq("Alice")
    String.new(t.record(0).field(1)).should eq("1502.30")
    String.new(t.record(0).field(2)).should eq("DEPOSIT")

    String.new(t.record(1).field(0)).should eq("Bob")
    String.new(t.record(1).field(1)).should eq("340.00")
    String.new(t.record(1).field(2)).should eq("WITHDRAWAL")
  end

  it "handles table without SOH header" do
    b = buf(
      C0::GS, "data",
      C0::RS, "a", C0::US, "b",
      C0::RS, "c", C0::US, "d"
    )
    t = C0::Table.new(b)
    t.header_count.should eq(0)
    t.record_count.should eq(2)
    String.new(t.record(0).field(0)).should eq("a")
    String.new(t.record(1).field(1)).should eq("d")
  end

  it "stops at next GS boundary" do
    b = buf(
      C0::GS, "t1",
      C0::RS, "a", C0::US, "b",
      C0::GS, "t2",
      C0::RS, "c", C0::US, "d"
    )
    t = C0::Table.new(b)
    t.record_count.should eq(1)
    String.new(t.name).should eq("t1")
  end

  it "stops at EOT" do
    b = buf(
      C0::GS, "t1",
      C0::RS, "x",
      C0::EOT
    )
    t = C0::Table.new(b)
    t.record_count.should eq(1)
    String.new(t.record(0).field(0)).should eq("x")
  end

  it "handles empty fields" do
    b = buf(
      C0::GS, "t",
      C0::RS, C0::US, "val", C0::US
    )
    t = C0::Table.new(b)
    t.record(0).field_count.should eq(3)
    t.record(0).field(0).size.should eq(0)
    String.new(t.record(0).field(1)).should eq("val")
    t.record(0).field(2).size.should eq(0)
  end

  it "handles DLE-escaped bytes in fields" do
    b = buf(
      C0::GS, "t",
      C0::RS, "hello", C0::DLE, C0::US, "world"
    )
    t = C0::Table.new(b)
    # DLE+US is escaped, so this is one field, not two
    t.record(0).field_count.should eq(1)
  end

  it "iterates records" do
    b = buf(
      C0::GS, "t",
      C0::RS, "a",
      C0::RS, "b",
      C0::RS, "c"
    )
    t = C0::Table.new(b)
    names = [] of String
    t.each_record { |r| names << String.new(r.field(0)) }
    names.should eq(["a", "b", "c"])
  end
end

describe "C0::Record#list" do
  it "splits an STX/ETX scope on top-level US and unescapes items" do
    b = buf(
      C0::GS, "t",
      C0::RS, "Alice",
      C0::US, C0::STX, "Admin", C0::US, "Ed", C0::DLE, C0::US, "itor", C0::US, "User", C0::ETX,
      C0::US, "1502.30"
    )
    rec = C0::Table.new(b).record(0)
    rec.field_count.should eq(3)
    rec.list(1).map { |i| String.new(i) }.should eq(["Admin", "Ed\u001Fitor", "User"])
  end

  it "does not split on US inside a nested scope within the list" do
    b = buf(
      C0::GS, "t",
      C0::RS, C0::STX, "a", C0::US, C0::STX, "x", C0::US, "y", C0::ETX, C0::US, "b", C0::ETX
    )
    items = C0::Table.new(b).record(0).list(0)
    items.size.should eq(3)
    String.new(items[0]).should eq("a")
    items[1][0].should eq(C0::STX)
    String.new(items[2]).should eq("b")
  end

  it "returns a plain field as a single-item list and an empty scope as empty" do
    b = buf(
      C0::GS, "t",
      C0::RS, "plain", C0::US, C0::STX, C0::ETX
    )
    rec = C0::Table.new(b).record(0)
    rec.list(0).map { |i| String.new(i) }.should eq(["plain"])
    rec.list(1).should eq([] of Bytes)
  end
end
