module C0
  annotation Field
  end

  # JSON::Serializable-style mapping of a class to one record under a
  # header row:
  #
  #   class User
  #     include C0::Serializable
  #     property name : String
  #     property roles : Array(String)
  #     @[C0::Field(key: "amt")]
  #     property amount : Float64
  #   end
  #
  #   User.new(...).to_c0        # => ␝user␁␞name␟roles␟amt␞Alice␟␐␞admin␘␟1.5
  #   User.from_c0(bytes)
  module Serializable
    macro included
      def self.from_c0(buf : Bytes) : self
        arr = array_from_c0(buf)
        arr.first? || raise C0::Error.new("No records found")
      end

      def self.from_c0(str : String) : self
        from_c0(C0::Pretty.parse(str))
      end

      def self.array_from_c0(buf : Bytes) : Array(self)
        body = C0::Document.new(buf).body
        group = body.groups.first? || raise C0::Error.new("No group found")
        headers = group.headers.map { |h| String.new(h) }
        results = Array(self).new(group.record_count)
        group.each_record do |rec|
          instance = allocate
          instance.initialize(__c0_headers: headers, __c0_record: rec)
          ::GC.add_finalizer(instance) if instance.responds_to?(:finalize)
          results << instance
        end
        results
      end

      def self.array_from_c0(str : String) : Array(self)
        array_from_c0(C0::Pretty.parse(str))
      end
    end

    def initialize(*, __c0_headers headers : Array(String), __c0_record rec : C0::Record)
      {% verbatim do %}
        {% begin %}
          {% for ivar in @type.instance_vars %}
            {% ann = ivar.annotation(C0::Field) %}
            {% unless ann && ann[:ignore] %}
              {% key = (ann && ann[:key]) || ivar.name.stringify %}
              %idx{ivar.id} = rec.keyed? ? (rec.has_key?({{ key }}) ? -1 : nil) : headers.index({{ key }})
              if %idx{ivar.id}
                {% if ivar.type == Array(String) %}
                  @{{ ivar.id }} = C0::Serializable._list(rec, %idx{ivar.id}.not_nil!, {{ key }})
                {% else %}
                  %str{ivar.id} = C0::Serializable._string(rec, %idx{ivar.id}.not_nil!, {{ key }})
                  {% if ivar.type == String %}
                    @{{ ivar.id }} = %str{ivar.id}
                  {% elsif ivar.type == Int32 %}
                    @{{ ivar.id }} = %str{ivar.id}.to_i32
                  {% elsif ivar.type == Int64 %}
                    @{{ ivar.id }} = %str{ivar.id}.to_i64
                  {% elsif ivar.type == Float32 %}
                    @{{ ivar.id }} = %str{ivar.id}.to_f32
                  {% elsif ivar.type == Float64 %}
                    @{{ ivar.id }} = %str{ivar.id}.to_f64
                  {% elsif ivar.type == Bool %}
                    @{{ ivar.id }} = %str{ivar.id} == "true"
                  {% elsif ivar.type.nilable? %}
                    if %str{ivar.id}.empty?
                      @{{ ivar.id }} = nil
                    else
                      {% inner = ivar.type.union_types.reject { |t| t == Nil }.first %}
                      {% if inner == String %}
                        @{{ ivar.id }} = %str{ivar.id}
                      {% elsif inner == Int32 %}
                        @{{ ivar.id }} = %str{ivar.id}.to_i32
                      {% elsif inner == Int64 %}
                        @{{ ivar.id }} = %str{ivar.id}.to_i64
                      {% elsif inner == Float32 %}
                        @{{ ivar.id }} = %str{ivar.id}.to_f32
                      {% elsif inner == Float64 %}
                        @{{ ivar.id }} = %str{ivar.id}.to_f64
                      {% elsif inner == Bool %}
                        @{{ ivar.id }} = %str{ivar.id} == "true"
                      {% end %}
                    end
                  {% end %}
                {% end %}
              {% if !ivar.has_default_value? && !ivar.type.nilable? %}
              else
                raise C0::Error.new("Missing required field '{{ key.id }}' for #{self.class}")
              {% end %}
              end
            {% end %}
          {% end %}
        {% end %}
      {% end %}
    end

    def to_c0(group_name : String? = nil) : Bytes
      io = IO::Memory.new
      to_c0(io, group_name)
      io.to_slice.dup
    end

    def to_c0_pretty(group_name : String? = nil) : String
      C0::Pretty.format(to_c0(group_name))
    end

    # Group label, header row, then this record.
    def to_c0(io : IO, group_name : String? = nil) : Nil
      {% verbatim do %}
        {% begin %}
          %name = group_name || {{ @type.name.split("::").last.downcase }}
          io.write_byte(C0::GS)
          C0.write_name(io, %name.to_slice)
          io.write_byte(C0::SOH)
          io.write_byte(C0::RS)
          {% fields = @type.instance_vars.reject { |v| (ann = v.annotation(C0::Field)) && ann[:ignore] } %}
          {% for ivar, i in fields %}
            {% ann = ivar.annotation(C0::Field) %}
            {% key = (ann && ann[:key]) || ivar.name.stringify %}
            io.write_byte(C0::US) if {{ i }} > 0
            C0.write_name(io, {{ key }}.to_slice)
          {% end %}
          _c0_write_record(io)
        {% end %}
      {% end %}
    end

    # RS + units, used by Array#to_c0 for the rows after the first.
    def _c0_write_record(io : IO) : Nil
      {% verbatim do %}
        {% begin %}
          {% fields = @type.instance_vars.reject { |v| (ann = v.annotation(C0::Field)) && ann[:ignore] } %}
          io.write_byte(C0::RS)
          {% for ivar, i in fields %}
            io.write_byte(C0::US) if {{ i }} > 0
            C0::Serializable._serialize_field(@{{ ivar.id }}, io)
          {% end %}
        {% end %}
      {% end %}
    end

    def self._serialize_field(value : String, io : IO) : Nil
      C0.write_value(io, value)
    end

    def self._serialize_field(value : Int | Float, io : IO) : Nil
      io << value
    end

    def self._serialize_field(value : Bool, io : IO) : Nil
      io << value
    end

    def self._serialize_field(value : Nil, io : IO) : Nil
    end

    # An array is a list: a level holding one record.
    def self._serialize_field(value : Array, io : IO) : Nil
      io.write_byte(C0::DLE)
      unless value.empty?
        io.write_byte(C0::RS)
        value.each_with_index do |item, i|
          io.write_byte(C0::US) if i > 0
          _serialize_field(item, io)
        end
      end
      io.write_byte(C0::CAN)
    end

    # A hash is a map: a level holding one keyed record, entries in hash order.
    def self._serialize_field(value : Hash, io : IO) : Nil
      io.write_byte(C0::DLE)
      io.write_byte(C0::RS)
      value.each do |k, v|
        io.write_byte(C0::SOH)
        C0.write_name(io, k.to_s.to_slice)
        io.write_byte(C0::US)
        _serialize_field(v, io)
      end
      io.write_byte(C0::CAN)
    end

    # A nested object is a level holding a header row and one record.
    def self._serialize_field(value : C0::Serializable, io : IO) : Nil
      io.write_byte(C0::DLE)
      inner = IO::Memory.new
      value.to_c0(inner)
      bytes = inner.to_slice
      # drop the group label: a level body starts with the header row
      start = 0
      start += 1 if bytes.size > 0 && bytes[0] == C0::GS
      while start < bytes.size && bytes[start] >= 0x20_u8
        start += 1
      end
      io.write(bytes[start...bytes.size])
      io.write_byte(C0::CAN)
    end

    def self._string(rec : C0::Record, idx : Int32, key : String) : String
      raw = idx < 0 ? (rec.field(key) || Bytes.empty) : rec.field(idx)
      String.new(C0.value(raw))
    end

    def self._list(rec : C0::Record, idx : Int32, key : String) : Array(String)
      raw = idx < 0 ? (rec.field(key) || Bytes.empty) : rec.field(idx)
      return Array(String).new if C0.trim(raw).empty?
      body = C0::Record.level_of(raw)
      recs = body.records
      return Array(String).new if recs.empty?
      recs[0].values.map { |v| String.new(v) }
    end
  end
end
