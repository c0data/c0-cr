require "json"
require "yaml"

module C0
  # JSON/YAML ⇄ C0DATA. Export never guesses: a positional record is an
  # array, a keyed record an object, a group with a header row an array of
  # objects, a reference `{"$ref": "group/record/field"}`.
  module JSON
    alias Value = String | Array(Value) | Hash(String, Value)

    # --- Export: C0DATA → JSON/YAML ---

    def self.to_json(buf : Bytes) : String
      export(buf).to_pretty_json
    end

    def self.to_yaml(buf : Bytes) : String
      export(buf).to_yaml
    end

    def self.export(buf : Bytes) : Value
      doc = Document.new(buf)
      export_body(doc.body)
    end

    # A body: {file => groups} per named file, or the groups directly;
    # a bare body (one unnamed group) exports as that group.
    def self.export_body(body : Body, level : Bool = false) : Value
      files = body.files
      if files.size == 1
        f = files[0]
        if f.name.empty?
          return export_groups(f.groups, level)
        end
        return {String.new(f.name) => export_groups(f.groups, level)} of String => Value
      end
      out = Hash(String, Value).new
      files.each { |f| out[String.new(f.name)] = export_groups(f.groups, level) }
      out.as(Value)
    end

    private def self.export_groups(groups : Array(Group), level : Bool = false) : Value
      return Array(Value).new.as(Value) if groups.empty?
      if groups.size == 1 && groups[0].name.empty? && groups[0].depth == 0
        return export_group(groups[0], level)
      end
      out = Hash(String, Value).new
      groups.each { |g| out[String.new(g.name)] = export_group(g) }
      out.as(Value)
    end

    # A group: with a header row, an array of objects; a single keyed
    # record is an object; otherwise an array of its records.
    def self.export_group(g : Group, level : Bool = false) : Value
      if g.has_header?
        headers = g.headers.map { |h| String.new(h) }
        rows = Array(Value).new
        g.records.each do |rec|
          if rec.keyed?
            rows << export_record(rec)
          else
            row = Hash(String, Value).new
            n = rec.field_count
            headers.each_with_index do |h, i|
              row[h] = i < n ? export_unit(rec, i) : "".as(Value)
            end
            rows << row.as(Value)
          end
        end
        return rows.as(Value)
      end
      recs = g.records
      return export_record(recs[0]) if recs.size == 1 && (recs[0].keyed? || level)
      arr = Array(Value).new
      recs.each { |r| arr << export_record(r) }
      arr.as(Value)
    end

    def self.export_record(rec : Record) : Value
      if rec.keyed?
        obj = Hash(String, Value).new
        rec.pairs.each_with_index do |(k, _v), i|
          obj[String.new(k)] = export_keyed_unit(rec, String.new(k))
        end
        obj.as(Value)
      else
        arr = Array(Value).new
        rec.field_count.times { |i| arr << export_unit(rec, i) }
        arr.as(Value)
      end
    end

    private def self.export_keyed_unit(rec : Record, key : String) : Value
      raw = rec.field(key) || Bytes.empty
      export_raw(raw)
    end

    private def self.export_unit(rec : Record, i : Int32) : Value
      export_raw(rec.field(i))
    end

    private def self.export_raw(raw : Bytes) : Value
      if C0.level?(raw)
        t = C0.trim(raw)
        export_body(Body.new(t, 1, Scan.level(t, 0) - 1), level: true)
      elsif C0.reference?(raw)
        r = Reference.parse(raw)
        {"$ref" => r.path.map { |s| String.new(s) }.join("/").as(Value)} of String => Value
      else
        String.new(C0.value(raw)).as(Value)
      end
    end

    # --- Import: JSON/YAML → C0DATA ---

    def self.from_json(input : String, group_name : String = "data") : Bytes
      emit_root(json_to_value(::JSON.parse(input)), group_name)
    end

    def self.from_yaml(input : String, group_name : String = "data") : Bytes
      emit_root(yaml_to_value(::YAML.parse(input)), group_name)
    end

    private def self.json_to_value(any : ::JSON::Any) : Value
      raw = any.raw
      case raw
      when Hash
        result = Hash(String, Value).new
        raw.each { |k, v| result[k] = json_to_value(v) }
        result.as(Value)
      when Array
        arr = Array(Value).new
        raw.each { |v| arr << json_to_value(v) }
        arr.as(Value)
      when String then raw.as(Value)
      when Nil    then "".as(Value)
      else             raw.to_s.as(Value)
      end
    end

    private def self.yaml_to_value(any : ::YAML::Any) : Value
      raw = any.raw
      case raw
      when Hash
        result = Hash(String, Value).new
        raw.each { |k, v| result[k.to_s] = yaml_to_value(v) }
        result.as(Value)
      when Array
        arr = Array(Value).new
        raw.each { |v| arr << yaml_to_value(v) }
        arr.as(Value)
      when String then raw.as(Value)
      when Nil    then "".as(Value)
      else             raw.to_s.as(Value)
      end
    end

    # Top-level layout: an object of groups (one key wrapping an object of
    # groups becomes a file); an array becomes one group; an object of
    # scalars becomes one group holding one map; a scalar one record.
    private def self.emit_root(value : Value, group_name : String) : Bytes
      Builder.build do |b|
        case value
        when Hash(String, Value)
          if value.size == 1 && (inner = value.first_value).is_a?(Hash) && all_groupable?(inner)
            b.file(value.first_key)
            emit_groups(b, inner)
          elsif all_groupable?(value)
            emit_groups(b, value)
          else
            b.group(group_name)
            emit_map(b, value)
          end
        when Array(Value)
          emit_array_as_group(b, value, group_name)
        when String
          b.group(group_name)
          b.record(value)
        end
      end
    end

    private def self.emit_groups(b : Builder, hash : Hash(String, Value)) : Nil
      hash.each do |name, value|
        case value
        when Hash(String, Value)
          b.group(name)
          emit_map(b, value)
        when Array(Value)
          emit_array_as_group(b, value, name)
        when String
          b.group(name)
          b.record(value)
        end
      end
    end

    # An object → one keyed record, entries in object order.
    private def self.emit_map(b : Builder, hash : Hash(String, Value)) : Nil
      b.record
      hash.each do |k, v|
        case v
        when String then b.key(k, v)
        else             b.key(k) { emit_level_body(b, v) }
        end
      end
    end

    private def self.emit_array_as_group(b : Builder, arr : Array(Value), name : String) : Nil
      if tabular?(arr)
        headers = arr[0].as(Hash(String, Value)).keys
        b.group(name, headers)
        arr.each do |row|
          h = row.as(Hash(String, Value))
          b.record
          headers.each { |k| emit_unit(b, h.fetch(k, "".as(Value))) }
        end
      else
        b.group(name)
        arr.each { |item| emit_item_as_record(b, item) }
      end
    end

    private def self.emit_item_as_record(b : Builder, item : Value) : Nil
      case item
      when String then b.record(item)
      when Array(Value)
        b.record
        item.each { |v| emit_unit(b, v) }
      when Hash(String, Value) then emit_map(b, item)
      end
    end

    # A value in unit position: scalar, or a level.
    private def self.emit_unit(b : Builder, value : Value) : Nil
      case value
      when String then b.field(value)
      else             b.level { emit_level_body(b, value) }
      end
    end

    # Inside a level: an array of scalars is one record (a list); an array
    # of uniform objects a table with a header row; an array of arrays a
    # table; a mixed array one record per item; an object a map.
    private def self.emit_level_body(b : Builder, value : Value) : Nil
      case value
      when Hash(String, Value)
        emit_map(b, value)
      when Array(Value)
        if value.all?(String)
          b.record
          value.each { |v| b.field(v.as(String)) }
        elsif tabular?(value)
          headers = value[0].as(Hash(String, Value)).keys
          b.header(headers)
          value.each do |row|
            h = row.as(Hash(String, Value))
            b.record
            headers.each { |k| emit_unit(b, h.fetch(k, "".as(Value))) }
          end
        elsif value.all?(Array(Value))
          value.each do |row|
            b.record
            row.as(Array(Value)).each { |v| emit_unit(b, v) }
          end
        else
          value.each { |item| emit_item_as_record(b, item) }
        end
      when String
        b.record(value)
      end
    end

    private def self.all_groupable?(hash : Hash(String, Value)) : Bool
      !hash.empty? && hash.all? { |_, v| v.is_a?(Hash) || v.is_a?(Array) }
    end

    private def self.tabular?(arr : Array(Value)) : Bool
      return false if arr.empty?
      return false unless arr.all?(Hash(String, Value))
      keys = arr[0].as(Hash(String, Value)).keys
      arr.all? { |item| item.as(Hash(String, Value)).keys == keys }
    end
  end
end
