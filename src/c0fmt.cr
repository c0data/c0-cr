# TODO: Add shell completion generation (Jargon supports bash/zsh/fish via --completions)
require "jargon"
require "./c0"
require "./c0/csv"
require "./c0/json"

SCHEMA = <<-YAML
---
name: import
description: Import CSV, JSON, or YAML into C0DATA compact format
positional:
  - format
  - file
properties:
  format:
    type: string
    description: Input format (csv, json, yaml) or input file. Auto-detected if omitted.
  file:
    type: string
    description: Input file (reads stdin if omitted)
  output:
    type: string
    short: o
    description: Output file (stdout if omitted)
  group:
    type: string
    short: g
    description: Group name (defaults to filename stem or 'data')
---
name: export
description: Export C0DATA to CSV, JSON, or YAML
positional:
  - format
  - file
required:
  - format
properties:
  format:
    type: string
    enum: [csv, json, yaml]
    description: Output format
  file:
    type: string
    description: Input C0DATA file (reads stdin if omitted)
  output:
    type: string
    short: o
    description: Output file (stdout if omitted)
---
name: pretty
description: Convert C0DATA to pretty-printed Unicode form
positional:
  - file
properties:
  file:
    type: string
    description: Input file (reads stdin if omitted)
  output:
    type: string
    short: o
    description: Output file (stdout if omitted)
---
name: compact
description: Convert C0DATA to compact binary form
positional:
  - file
properties:
  file:
    type: string
    description: Input file (reads stdin if omitted)
  output:
    type: string
    short: o
    description: Output file (stdout if omitted)
---
name: validate
description: Validate C0DATA structure
positional:
  - file
properties:
  file:
    type: string
    description: Input file (reads stdin if omitted)
  stream:
    type: boolean
    short: s
    description: Validate as a stream-mode log (report torn tail)
YAML

cli = Jargon.cli("c0fmt", yaml: SCHEMA)

cli.run do |result|
  input_file = result["file"]?.try(&.as_s)
  output_file = result["output"]?.try(&.as_s)

  # Read input from file or stdin
  input = if file = input_file
             File.read(file)
           else
             STDIN.gets_to_end
           end

  res = case result.subcommand
        when "import"
          # First positional could be a format (csv/json/yaml) or a file path
          raw_format = result["format"]?.try(&.as_s)
          if raw_format && !{"csv", "json", "yaml"}.includes?(raw_format)
            # It's actually a file path, not a format
            input_file = raw_format
            input = File.read(input_file)
            raw_format = nil
          end
          format = raw_format || detect_format(input_file, input)
          gname = result["group"]?.try(&.as_s) || input_file.try { |f| File.basename(f, File.extname(f)) } || "data"

          buf = case format
                when "csv"  then C0::CSV.from_csv(input, group_name: gname)
                when "json" then C0::JSON.from_json(input, group_name: gname)
                when "yaml" then C0::JSON.from_yaml(input, group_name: gname)
                else
                  STDERR.puts "Cannot detect input format. Specify: c0fmt import <csv|json|yaml> [file]"
                  exit 1
                end
          String.new(buf)

        when "export"
          format = result["format"].as_s
          buf = to_compact(input)

          case format
          when "csv"  then C0::CSV.to_csv(buf)
          when "json" then C0::JSON.to_json(buf)
          when "yaml" then C0::JSON.to_yaml(buf)
          else raise "unreachable"
          end

        when "pretty"
          buf = to_compact(input)
          C0::Pretty.format(buf)

        when "compact"
          buf = to_compact(input)
          String.new(buf)

        when "validate"
          buf = to_compact(input)
          if result["stream"]?.try(&.as_bool)
            reader = C0::Stream::Reader.new(buf)
            begin
              C0::Tokenizer.new(reader.committed).each { }
            rescue ex : C0::Error
              STDERR.puts "invalid: #{ex.message}"
              exit 1
            end
            if reader.torn?
              STDERR.puts "torn: #{reader.tail.size} uncommitted byte(s) after " \
                          "#{reader.block_count} committed block(s)"
              exit 1
            end
            STDERR.puts "valid: #{reader.block_count} committed block(s)"
            exit 0
          end
          begin
            C0::Tokenizer.new(buf).each { }
            STDERR.puts "valid"
            exit 0
          rescue ex : C0::Error
            STDERR.puts "invalid: #{ex.message}"
            exit 1
          end
        end

  # Write output
  if res
    if file = output_file
      File.write(file, res)
    else
      print res
    end
  end
end

# Detect if input contains Unicode Control Pictures (pretty format)
def pretty_input?(input : String) : Bool
  input.each_char do |c|
    return true if c.ord >= 0x2400 && c.ord <= 0x241F
  end
  false
end

# Convert input to compact bytes, auto-detecting pretty vs compact
def to_compact(input : String) : Bytes
  if pretty_input?(input)
    C0::Pretty.parse(input)
  else
    input.to_slice
  end
end

# Auto-detect import format from file extension or content sniffing
def detect_format(file : String?, content : String) : String?
  # Try file extension first
  if f = file
    case File.extname(f).downcase
    when ".csv"           then return "csv"
    when ".json"          then return "json"
    when ".yaml", ".yml"  then return "yaml"
    end
  end

  # Sniff content
  trimmed = content.lstrip
  if trimmed.starts_with?('{') || trimmed.starts_with?('[')
    "json"
  elsif trimmed.starts_with?("---")
    "yaml"
  else
    "csv"
  end
end
