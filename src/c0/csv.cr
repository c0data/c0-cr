require "csv"

module C0
  module CSV
    # CSV text → one group with a header row and positional records.
    def self.from_csv(input : String, group_name : String = "data") : Bytes
      rows = ::CSV.parse(input)
      return Bytes.empty if rows.empty?
      Builder.build do |b|
        b.group(group_name, rows[0])
        rows[1..].each { |row| b.record(row) }
      end
    end

    # The first group of a buffer → CSV text (header row first if present).
    def self.to_csv(buf : Bytes) : String
      g = find_group(buf)
      ::CSV.build do |csv|
        if g.has_header?
          csv.row { |row| g.headers.each { |h| row << String.new(h) } }
        end
        g.each_record do |rec|
          csv.row { |row| rec.values.each { |v| row << String.new(v) } }
        end
      end
    end

    private def self.find_group(buf : Bytes) : Group
      body = Document.new(buf).body
      body.groups.first? || raise Error.new("no group in buffer")
    end
  end
end
