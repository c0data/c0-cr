# C0DATA

A data system built on ASCII C0 control codes. One vocabulary, multiple shapes
-- tabular data, hierarchical documents, key-value config, diffs, logs, and
more.

C0DATA sits between human-readable text formats (JSON, YAML, TOML) and opaque
binary formats (protobuf, msgpack). Values are plain UTF-8 text. Structure is
expressed through single-byte control codes -- compact, zero-copy friendly,
and inspectable with minimal tooling.

This is the Crystal reference implementation of the 2026-10 (pre-1.0)
redesign, specified in [c0-spec](https://github.com/c0data/c0-spec).

## The Idea

ASCII has 32 control codes (0x00-0x1F) that were designed in the 1960s for
structuring data transmissions. Four of them -- FS, GS, RS, US -- are literal
**data separators** at four hierarchical levels. C0DATA takes them, and a
dozen of their neighbours, at their word.

```
␖␜mydb
  ␝users
    ␁␞name␟amount␟type
    ␞Alice␟1502.30␟DEPOSIT
    ␞Bob␟340.00␟WITHDRAWAL
  ␝products
    ␁␞id␟product␟qty
    ␞01␟Widget␟100
    ␞02␟Gadget␟250
␄
```

That's a complete document with two tables, header rows, and typed rows.
Each glyph (␖ ␜ ␝ ␁ ␞ ␟ ␄) is a single-byte control code. No braces, no
commas; quoting only where a value holds whitespace or a control code.
Whitespace touching a control code is layout -- the indentation is just for
readability.

## Control Codes

| Byte | Abbr | Glyph | Role |
|------|------|-------|------|
| 0x01 | SOH | ␁ | A key for the value after it; `␁␞` a header row |
| 0x02 | STX | ␂ | Start of text (a literal value) |
| 0x03 | ETX | ␃ | End of text |
| 0x04 | EOT | ␄ | End of document |
| 0x05 | ENQ | ␅ | Reference |
| 0x07 | BEL | ␇ | Comment: a note, or marks the next element dead |
| 0x10 | DLE | ␐ | Recurse: open a nested level (escape inside text) |
| 0x16 | SYN | ␖ | Start of document, then the heading |
| 0x17 | ETB | ␗ | Commit marker (stream mode) |
| 0x18 | CAN | ␘ | Close a nested level |
| 0x19 | EM  | ␙ | End of medium: a raw blob follows |
| 0x1A | SUB | ␚ | Substitution (C0-DIFF) |
| 0x1C | FS  | ␜ | File separator |
| 0x1D | GS  | ␝ | Group / table / section separator |
| 0x1E | RS  | ␞ | Record / row separator |
| 0x1F | US  | ␟ | Unit / field separator |

## Data Shapes

### Tabular

```
␝users
  ␁␞name␟amount␟type
  ␞Alice␟1502.30␟DEPOSIT
```

### Key-value (a keyed record is a map)

```
␝database
  ␞␁host␟localhost␁port␟5432
```

### Nested values

A field can hold a whole level: a list, a table, a map, even a document.

```
␞Alice␟␐␞Admin␟Editor␘␟␐␞␁city␟Springfield␁street␟1 Main␘
```

### Text

A value with edge whitespace, a line break, a tab or any control code is
written as text; inside, only seven codes need a `␐` escape.

```
␞note␟␂line one
line two␃
```

### Document

```
␖␜My Document
␝Chapter 1
␞First paragraph.
␝␝Section 1.1
␞Nested content.
␄
```

### Stream (append-only logs)

ETB commits each appended block; a crashed append never writes its
commit, so replay skips the torn tail.

```
␖␁shape␟stream␁␞op␟id␗
␞create␟a1b2␗
␞name␟draft-2␗
```

### Diff

Anchored patterns, with `␞old␚new` for replace-all within a section's
scope. See `DIFF.md` in the spec.

```
␖␁shape␟diff
␜tally.rb
␝def tally(items)
␞count␚total
␝end
␄
```

## Performance

The scanner's hot loop is a single comparison: `byte < 0x20`. Single-byte
delimiters, zero-copy reads, SIMD-friendly.

## Installation

```yaml
dependencies:
  c0:
    github: c0data/c0-cr
```

## Usage

```crystal
require "c0"
```

### Building

```crystal
buf = C0::Builder.build do |b|
  b.syn(shape: "tabular")
  b.file("mydb")
  b.group("users", ["name", "amount", "roles"]) do
    b.record
    b.field("Alice")
    b.field("1502.30")
    b.list(["Admin", "Editor"])          # ␐␞Admin␟Editor␘
  end
  b.group("config")
  b.map({"port" => "5432", "host" => "localhost"})   # order kept
  b.eot
end
```

Values are written in their one canonical spelling: plain when they can
be, text otherwise. `b.level { ... }` opens a nested level as the next
unit; `b.key(name, value)` adds a keyed unit; `b.note(text)` a comment.

### Reading

```crystal
doc = C0::Document.new(buf)
doc.heading.shape                 # => "tabular"
doc.name                          # => "mydb"
users = doc["users"]
users.headers                     # => ["name", "amount", "roles"]
rec = users.record(0)
rec.value(0)                      # => "Alice" (zero-copy slice)
rec.list(2)                       # => ["Admin", "Editor"]
rec.level(2).records              # the same level, as a body
doc["config"].record(0)["host"]   # => "localhost"
doc.warnings                      # missing SYN/EOT, unknown heading keys
```

`C0::Container.new(buf)` reads a file holding several documents and an EM
blob tail (`container.blob("name")`). `C0.validate(bytes)` checks
well-formedness against the grammar; `C0.canonical?(bytes)` checks the
canonical constraints.

### Pretty form

```crystal
puts C0::Pretty.format(buf)                       # one element per line
puts C0::Pretty.format(buf, mode: C0::Pretty::FormatMode::Spaced)
C0::Pretty.parse(pretty) == buf                  # round trip
```

### Serializable

```crystal
class User
  include C0::Serializable
  property name : String
  property roles : Array(String)        # a list level
  @[C0::Field(key: "amt")]
  property amount : Float64
  def initialize(@name, @roles, @amount); end
end

User.new("Alice", ["admin"], 1.5).to_c0   # ␝user␁␞name␟roles␟amt␞Alice␟␐␞admin␘␟1.5
User.from_c0(bytes)
[u1, u2].to_c0
{"b" => "2", "a" => "1"}.to_c0("cfg")      # ␝cfg␞␁a␟1␁b␟2
```

### JSON / YAML / CSV

```crystal
C0::JSON.to_json(buf)        # positional record → array, keyed → object,
C0::JSON.from_json(json)     # header row → array of objects; nothing guessed
C0::JSON.to_yaml(buf) / C0::JSON.from_yaml(yaml)
C0::CSV.from_csv(csv, "users") / C0::CSV.to_csv(buf)
```

### C0-DIFF

```crystal
diff = C0::Diff.build do |d|
  d.file("tally.rb") do
    d.section { |s| s.anchor("def tally(items)") }
    d.replace_all("count", "total")
    d.section { |s| s.anchor("end") }
  end
end
C0::Diff.apply(diff, {"tally.rb" => source})   # validates everything first
C0::Diff.apply_files(diff, "src")
```

### Stream logs

```crystal
C0::Stream::Writer.open("events.c0") do |w|
  w.start                              # SYN heading, committed
  w.header("op", "id")
  w.record("create", "a1")
  w.batch { |b| b.record("a", "1"); b.record("b", "2") }   # one commit
end

r = C0::Stream::Reader.read("events.c0")
r.torn?            # uncommitted tail?
r.damaged          # blocks cut by a commit inside open text or a level
r.each_record { |rec| ... }
```

`Writer.open` repairs a torn tail before appending.

## Conformance

The shared vectors live in the [c0-spec](https://github.com/c0data/c0-spec)
submodule at `c0-spec/` (`git submodule update --init` after cloning);
`crystal spec` runs them along with the unit specs.

## c0fmt

The command-line tool lives in its own repository:
https://github.com/c0data/c0-fmt.

## License

MIT
