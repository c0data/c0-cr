class Array(T)
  # Serializable items → one group with a header row and one record each.
  def to_c0(group_name : String? = nil) : Bytes
    raise C0::Error.new("Cannot serialize empty array") if empty?
    io = IO::Memory.new
    first.to_c0(io, group_name)
    each_with_index do |item, idx|
      next if idx == 0
      item._c0_write_record(io)
    end
    io.to_slice.dup
  end

  def to_c0_pretty(group_name : String? = nil) : String
    C0::Pretty.format(to_c0(group_name))
  end
end

struct NamedTuple
  # One group holding one keyed record.
  def to_c0(group_name : String = "data") : Bytes
    io = IO::Memory.new
    io.write_byte(C0::GS)
    C0.write_name(io, group_name.to_slice)
    io.write_byte(C0::RS)
    {% for key in T.keys.sort %}
      io.write_byte(C0::SOH)
      C0.write_name(io, {{ key.stringify }}.to_slice)
      io.write_byte(C0::US)
      C0::Serializable._serialize_field(self[{{ key.symbolize }}], io)
    {% end %}
    io.to_slice.dup
  end

  def to_c0_pretty(group_name : String = "data") : String
    C0::Pretty.format(to_c0(group_name))
  end
end

class Hash(K, V)
  # One group holding one keyed record, keys sorted.
  def to_c0(group_name : String = "data") : Bytes
    io = IO::Memory.new
    io.write_byte(C0::GS)
    C0.write_name(io, group_name.to_slice)
    io.write_byte(C0::RS)
    keys.map(&.to_s).sort!.each do |k|
      io.write_byte(C0::SOH)
      C0.write_name(io, k.to_slice)
      io.write_byte(C0::US)
      v = self[keys.find! { |kk| kk.to_s == k }]
      C0::Serializable._serialize_field(v, io)
    end
    io.to_slice.dup
  end

  def to_c0_pretty(group_name : String = "data") : String
    C0::Pretty.format(to_c0(group_name))
  end
end
