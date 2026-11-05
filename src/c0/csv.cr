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

    # A group → CSV text (header row first if present): the first group of
    # the buffer, or the named one. A reference is written as its path
    # (`tags/001`); a nested level has no CSV form and is an error.
    def self.to_csv(buf : Bytes, group_name : String? = nil) : String
      g = find_group(buf, group_name)
      ::CSV.build do |csv|
        if g.has_header?
          csv.row { |row| g.headers.each { |h| row << String.new(h) } }
        end
        g.each_record do |rec|
          csv.row do |row|
            rec.fields.each_with_index do |f, i|
              if C0.level?(f)
                raise Error.new("CSV cannot carry a nested level (group '#{String.new(g.name)}', field #{i + 1})")
              elsif C0.reference?(f)
                row << Reference.parse(f).path.map { |seg| String.new(seg) }.join('/')
              else
                row << String.new(C0.value(f))
              end
            end
          end
        end
      end
    end

    private def self.find_group(buf : Bytes, name : String?) : Group
      body = Document.new(buf).body
      if name
        body.groups.find { |g| String.new(g.name) == name } ||
          raise Error.new("no group named '#{name}'")
      else
        body.groups.first? || raise Error.new("no group in buffer")
      end
    end
  end
end
