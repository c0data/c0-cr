# C0DATA

A data system built on ASCII C0 control codes. One vocabulary, multiple shapes
-- tabular data, hierarchical documents, key-value config, diffs, and more.

C0DATA sits between human-readable text formats (JSON, YAML, TOML) and opaque
binary formats (protobuf, msgpack). Values are plain UTF-8 text. Structure is
expressed through single-byte control codes -- compact, zero-copy friendly,
and inspectable with minimal tooling.

## The Idea

ASCII has 32 control codes (0x00-0x1F) that were designed in the 1960s for
structuring data transmissions. Four of them -- FS, GS, RS, US -- are literal
**data separators** at four hierarchical levels. C0DATA modernizes these codes
as a universal grammar for structured data.

```
␜mydb
  ␝users
    ␁name␟amount␟type
    ␞Alice␟1502.30␟DEPOSIT
    ␞Bob␟340.00␟WITHDRAWAL
  ␝products
    ␁id␟product␟qty
    ␞01␟Widget␟100
    ␞02␟Gadget␟250
␄
```

That's a complete database with two tables, headers, and typed rows. Each
glyph (␜ ␝ ␞ ␟ ␁ ␄) is a single-byte control code. No braces, no quotes,
no escaping. Whitespace around control codes is trimmed -- the indentation
is just for readability.

## Control Codes

| Byte | Abbr | Role |
|------|------|------|
| 0x01 | SOH | Header (declares field names) |
| 0x02 | STX | Open nested sub-structure |
| 0x03 | ETX | Close nested sub-structure |
| 0x04 | EOT | End of document |
| 0x05 | ENQ | Reference (look up named data) |
| 0x10 | DLE | Escape (next byte is literal) |
| 0x17 | ETB | Commit marker (stream mode) |
| 0x1A | SUB | Substitution (C0DIFF) |
| 0x1C | FS  | File / Database separator |
| 0x1D | GS  | Group / Table / Section separator |
| 0x1E | RS  | Record / Row separator |
| 0x1F | US  | Unit / Field separator |

## Data Shapes

The same codes express multiple common data shapes:

### Tabular (CSV, SQL)

```
␝users
  ␁name␟amount␟type
  ␞Alice␟1502.30␟DEPOSIT
  ␞Bob␟340.00␟WITHDRAWAL
```

### Key-Value (TOML, INI)

```
␝database
  ␞host␟localhost
  ␞port␟5432
␝server
  ␞host␟0.0.0.0
  ␞port␟8080
```

### Document (Markdown)

GS repeated indicates depth level (like # in Markdown):

```
␜My Document
  ␝Chapter 1
    ␞First paragraph.
    ␞A list:
      ␟Item one
      ␟Item two
    ␝␝Section 1.1
      ␞Nested content.
  ␝Chapter 2
    ␞And so on.
```

### Diff (Atomic Multi-File Edits)

C0DIFF uses anchored patterns for safe search-and-replace:

```
␜foo.txt
  ␝Hello ␟world␚universe␟!
```

Means: in `foo.txt`, find `Hello world!`, replace `world` with `universe`.

### Stream (Append-Only Logs)

For event logs and write-ahead logs, ETB (␗) commits each appended block.
A crashed append never writes its commit marker, so replay skips the torn
tail instead of folding corrupt state:

```
␞create␟a1b2␗
␞name␟draft-2␗
```

A block may hold several records under one commit — an atomic batch.

### Whitespace and Quoting

In pretty form, whitespace around control codes is trimmed. To preserve
significant whitespace, use STX/ETX as quotes:

```
␞␂  leading spaces  ␃␟normal value
```

## Performance

The scanner's hot loop is a single comparison: `byte < 0x20`. This makes
C0DATA inherently fast to parse -- single-byte delimiters, zero-copy
friendly, and SIMD-acceleratable.

Benchmark on 10 MB document (Crystal, --release):

```
  avg         4.88 ms       2048.0 MB/s
  best        4.09 ms       2447.7 MB/s
```

For comparison, a fast YAML scanner in C achieves ~420 MB/s on equivalent data.

## Installation

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  c0:
    github: trans/c0data
```

Then run `shards install`.

## Usage

```crystal
require "c0"
```

### Serializable

Like `JSON::Serializable`, include `C0::Serializable` in a class to get
`to_c0` and `from_c0` methods:

```crystal
class User
  include C0::Serializable

  property name : String
  property amount : String

  def initialize(@name = "", @amount = "")
  end
end

# Serialize
user = User.new("Alice", "1502.30")
buf = user.to_c0               # => Bytes (compact form)
str = user.to_c0_pretty        # => String (pretty form)

# Deserialize
user = User.from_c0(buf)
user = User.from_c0(pretty_string)

# Collections
users = [User.new("Alice", "100"), User.new("Bob", "200")]
buf = users.to_c0              # multi-record group
restored = User.array_from_c0(buf)
```

Field annotations:

```crystal
class Product
  include C0::Serializable

  @[C0::Field(key: "product_id")]
  property id : Int32 = 0

  @[C0::Field(ignore: true)]
  property internal : String = ""

  property name : String = ""

  def initialize(@id = 0, @name = "", @internal = "")
  end
end
```

Hashes and named tuples serialize as key-value groups:

```crystal
{"host" => "localhost", "port" => "5432"}.to_c0("database")
{host: "localhost", port: "5432"}.to_c0("config")
```

### Building

```crystal
buf = C0::Builder.build do |b|
  b.file("mydb") do
    b.group("users", headers: ["name", "amount", "type"]) do
      b.record("Alice", "1502.30", "DEPOSIT")
      b.record("Bob", "340.00", "WITHDRAWAL")
    end
  end
  b.eot
end
```

### Reading

```crystal
doc = C0::Document.new(buf)
doc.name                                # => "mydb"
doc["users"].table.record(0).field(0)   # => "Alice" (zero-copy slice)
doc["users"].table.record(0).field(1)   # => "1502.30"
```

### Pretty-Printing

```crystal
puts C0::Pretty.format(buf)
# ␜mydb
#   ␝users
#     ␁name␟amount␟type
#     ␞Alice␟1502.30␟DEPOSIT
#     ␞Bob␟340.00␟WITHDRAWAL
#   ␄
```

### Round-Trip

```crystal
pretty = C0::Pretty.format(buf)
compact = C0::Pretty.parse(pretty)
# compact is identical to the original buf
```

### CSV Conversion

```crystal
# CSV → C0DATA
buf = C0::CSV.from_csv(csv_string, group_name: "users")

# C0DATA → CSV
csv = C0::CSV.to_csv(buf)
```

### JSON/YAML Conversion

```crystal
# JSON → C0DATA
buf = C0::JSON.from_json(json_string)

# YAML → C0DATA
buf = C0::JSON.from_yaml(yaml_string, group_name: "config")

# C0DATA → JSON
json = C0::JSON.to_json(buf)

# C0DATA → YAML
yaml = C0::JSON.to_yaml(buf)
```

Tables become arrays of objects, key-value groups become flat objects.
Nested JSON/YAML structures are preserved using STX/ETX scoping.

### C0DIFF

```crystal
diff = C0::Diff.build do |b|
  b.file("src/app.cr") do
    b.section do |s|
      s.anchor("class App\n  def ")
      s.sub("run", "start")
    end
  end
end

files = {"src/app.cr" => source_code}
result = C0::Diff.apply(diff, files)
```

### Stream Logs

```crystal
C0::Stream::Writer.open("claims.c0") do |log|
  log.record("create", nonce, ts)
  log.batch do |b|              # atomic multi-record commit
    b.record("name", label, ts)
    b.record("tag", tag, ts)
  end
end

reader = C0::Stream::Reader.read("claims.c0")
reader.torn?                          # uncommitted tail present?
reader.each_record { |rec| ... }      # committed records only
```

`Writer.open` repairs a torn tail before appending. `c0fmt validate -s`
checks a log from the command line.

## Two Forms

C0DATA has two representations:

- **Compact** -- canonical wire/storage format. Every byte is literal.
  No whitespace is ignored.
- **Pretty** -- human-readable. Uses Unicode Control Pictures (U+2400 block)
  for visible glyphs. Newlines and indentation are ignored by the parser.

Compact form is canonical in the strong sense: the same logical value
encodes to exactly one byte sequence, so compact bytes can be hashed for
content addressing (see DESIGN.md "Canonical Form"). `C0.canonical?(buf)`
checks a buffer; the shared conformance vectors live in the
[c0-spec](https://github.com/trans/c0-spec) submodule at `c0-spec/` (run
`git submodule update --init` after cloning).

The `c0fmt` command-line tool converts between them and more.

## c0fmt

`c0fmt` is a CLI tool for working with C0DATA from the command line.

```
c0fmt <command> [options] [file]

Commands:
  import [format] [file]   Import CSV, JSON, or YAML to C0DATA
  export <format> [file]   Export C0DATA to CSV, JSON, or YAML
  pretty [file]            Convert to pretty-printed Unicode form
  compact [file]           Convert to compact binary form
  validate [file]          Check well-formedness

Options:
  -o, --output FILE    Write to file (default: stdout)
  -g, --group NAME     Group name for import (default: filename stem)
  -h, --help           Show help
```

Reads from a file argument or stdin. The import command auto-detects
format from file extension (.csv, .json, .yaml, .yml) or content.

### Examples

Convert a CSV file to pretty-printed C0DATA:

```sh
c0fmt import data.csv | c0fmt pretty
```

```
␝data
  ␁name␟amount
  ␞Alice␟100
  ␞Bob␟200
```

Round-trip through C0DATA and back to CSV:

```sh
c0fmt import csv users.csv | c0fmt export csv
```

Import JSON and view as pretty C0DATA:

```sh
echo '{"users": [{"name": "Alice"}, {"name": "Bob"}]}' | c0fmt import | c0fmt pretty
```

```
␝users
  ␁name
  ␞Alice
  ␞Bob
```

Export to JSON or YAML:

```sh
c0fmt import users.csv | c0fmt export json
```

```json
{
  "users": [
    {"name": "Alice", "amount": "100"},
    {"name": "Bob", "amount": "200"}
  ]
}
```

```sh
c0fmt import users.csv | c0fmt export yaml
```

```yaml
---
users:
- name: Alice
  amount: "100"
- name: Bob
  amount: "200"
```

Validate a C0DATA file:

```sh
c0fmt validate data.c0
```

Convert between pretty and compact forms:

```sh
c0fmt compact pretty.c0 -o data.c0    # pretty → compact
c0fmt pretty data.c0                   # compact → pretty
```

### Building c0fmt

```sh
crystal build src/c0fmt.cr -o bin/c0fmt --release
```

## Design

See [DESIGN.md](DESIGN.md) for the full specification, including open
questions and future directions.

## Development

```
crystal spec        # run tests
crystal build bench/bench_tokenizer.cr -o bench/bench_tokenizer --release
./bench/bench_tokenizer 10   # benchmark with 10 MB document
```

## License

MIT
