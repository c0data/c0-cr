---
title: C0DATA Technical Reference
---

# C0DATA Technical Reference

## Format Overview

C0DATA uses ASCII C0 control codes (0x00--0x1F) as structural delimiters
with UTF-8 text values. It sits between human-readable text formats (JSON,
YAML, TOML) and opaque binary formats (protobuf, msgpack). Values are plain
text. Structure is expressed through single-byte control codes.

See [DESIGN.md](https://github.com/trans/c0data/blob/main/DESIGN.md) for the
full specification and future directions.

### Assigned Control Codes

| Byte | Abbr | Glyph | Role |
|------|------|-------|------|
| 0x01 | SOH | ␁ | Header (declares field names) |
| 0x02 | STX | ␂ | Open nested sub-structure |
| 0x03 | ETX | ␃ | Close nested sub-structure |
| 0x04 | EOT | ␄ | End of document / message |
| 0x05 | ENQ | ␅ | Reference (look up named data) |
| 0x10 | DLE | ␐ | Escape (next byte is literal) |
| 0x17 | ETB | ␗ | Commit marker (stream mode) |
| 0x1A | SUB | ␚ | Substitution (C0DIFF) |
| 0x1C | FS  | ␜ | File / Database separator |
| 0x1D | GS  | ␝ | Group / Table / Section separator |
| 0x1E | RS  | ␞ | Record / Row separator |
| 0x1F | US  | ␟ | Unit / Field separator |

All other C0 codes (0x00--0x1F) are currently **reserved**. A parser should
raise an error on unassigned codes.

### Structural Hierarchy

The four separator codes form a fixed hierarchy:

```
FS  >  GS  >  RS  >  US
file   group  record  field
```

- **FS (0x1C)** -- Top-level container. A database, a file, a document.
- **GS (0x1D)** -- A group within a file. A table, a collection, a section.
- **RS (0x1E)** -- A record within a group. A row, an entry, a block.
- **US (0x1F)** -- A unit within a record. A field, a property, an element.

Text immediately following FS or GS is the **label** (name) for that scope.


---

## Two Forms: Compact and Pretty

C0DATA has two representations of the same data.

### Compact Form (Canonical)

The wire/storage format. A continuous byte stream. Every byte between control
codes is literal data -- including LF, CR, HT, and spaces. No whitespace is
ignored. This is the canonical form.

```
[FS]mydb[GS]users[SOH]name[US]amount[RS]Alice[US]1502.30[RS]Bob[US]340.00
```

### Pretty Form (Human-Readable)

Uses Unicode Control Pictures (U+2400 block) for visible glyphs. Whitespace
rules:

- LF and CR are ignored (formatting only).
- Whitespace (spaces, tabs) adjacent to control codes is trimmed.
- Spaces between non-whitespace data characters are preserved
  (e.g., "Alice Smith" keeps its space).
- Inside STX/ETX (␂...␃), all content is preserved verbatim --
  no trimming. This allows STX/ETX to serve as quoting for values
  with significant leading/trailing whitespace.

```
␜mydb
  ␝users
    ␁name␟amount
    ␞Alice Smith␟1502.30
    ␞Bob␟340.00
```

To include a literal LF or CR in a value, DLE-escape it: `[DLE][LF]`.

Quoting with STX/ETX:

```
␞␂  leading spaces  ␃␟normal value
```


---

## Data Shapes

C0DATA is a system, not a single format. The same control code vocabulary
expresses multiple common data shapes.

| Shape      | Primary Codes Used          | Analogous To         |
|------------|-----------------------------|----------------------|
| Tabular    | FS, GS, SOH, RS, US        | CSV, SQL results     |
| Document   | FS, GS×N, RS, US           | Markdown, outlines   |
| Key-Value  | GS, SOH, RS, US            | TOML, INI            |
| Nested     | STX/ETX, any inner codes   | JSON objects         |
| Reference  | ENQ, STX/ETX for paths     | foreign keys, links  |
| Diff       | FS, GS, US, SUB, DLE       | unified diff, patches|
| Stream     | EOT between documents      | NDJSON, SSE          |

### Tabular (SOH header present)

SOH at the start of a group declares field names. Records are positional
against those names -- like a CSV header row.

```
␝users
  ␁name␟amount
  ␞Alice␟100
  ␞Bob␟200
```

Without SOH, data is purely positional (schema known by both sides).

### Key-Value (no header, 2-field records)

Each RS is an entry: first field is the key, second is the value.

```
␝database
  ␞host␟localhost
  ␞port␟5432
```

### Multi-field records (no header, N fields)

```
␝data
  ␞a␟b␟c
  ␞d␟e␟f
```

### Nested values (STX/ETX)

When a field value is itself structured, wrap it in STX/ETX. Inside the
brackets, the separator hierarchy resets -- codes are scoped to the
sub-structure. STX/ETX can nest for arbitrary depth.

```
␝users
  ␁name␟address
  ␞Alice␟␂␁street␟city␞123 Main␟Springfield␃
```

Arrays are US-separated values inside STX/ETX:

```
␞Alice␟␂Admin␟Editor␟User␃␟1502.30
```

### Document (FS wrapper, depth via GS repetition)

GS repeated indicates depth level (like # in Markdown). Within a section,
RS marks a content block (paragraph) and US marks sub-elements (list items).

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

### References (ENQ)

ENQ marks a value as a reference to data defined elsewhere. Referenced
material must be defined **before** any reference to it (enabling single-pass
parsing).

Simple reference (entire group):

```
␅tags
```

Path reference (record or field within a group):

```
␅␂tags␟001␟label␃
```

STX/ETX scopes the reference. US separates path segments:
group → record id → field name.


---

## C0DIFF

C0DIFF provides atomic multi-file edits using **anchored patterns**. Instead
of line numbers (which shift), you provide literal context text as anchors
surrounding the parts you want to change.

### How It Works

A section is a sequence of **units** separated by US. Each unit is either:

- **Anchor text** -- literal content that must match exactly (provides context)
- **Substitution** -- `old[SUB]new` (the part that actually changes)

Units are concatenated to build a search pattern. The pattern must match
**exactly once** in the file. Then only the SUB-marked parts are replaced.

### Example

Given a file `greeting.txt` containing `Hello world!`:

```
␜greeting.txt
  ␝Hello ␟world␚universe␟!
```

This breaks down as:

| Unit | Type | Search contributes | Replacement contributes |
|------|------|-------------------|------------------------|
| `Hello ` | anchor | `Hello ` | `Hello ` |
| `world␚universe` | substitution | `world` | `universe` |
| `!` | anchor | `!` | `!` |

Search pattern: `Hello world!` (must match exactly once).
Replacement: `Hello universe!` (only `world` → `universe` changes).

### Anchors

You can anchor on one side, both sides, or use multiple substitutions:

```
# Anchor before only (enough if "def run" is unique in context)
␝class App\n  def ␟run␚start

# Anchors before and after (more precise)
␝Hello ␟world␚universe␟!

# Multiple substitutions in one section
␝x = ␟10␚20␟ + ␟5␚15
# Finds "x = 10 + 5", produces "x = 20 + 15"
```

### Atomicity Guarantee

1. **Validate first** -- every section's search pattern is checked against
   every target file. Each pattern must match **exactly once**. Zero
   matches → error. Multiple matches → error.
2. **Apply only if all pass** -- if any pattern in any file fails validation,
   **nothing is modified**. No partial writes, no half-applied diffs.
3. **Then write** -- all replacements are applied and files are written.

A C0DIFF document is an all-or-nothing transaction across multiple files.

### Relationship to C0DATA

C0DIFF shares the same control code vocabulary. FS and GS retain their
structural meanings (file boundary, section/group boundary). US retains
its role as a unit-level separator. DLE is the same escape mechanism.
SUB takes on a diff-specific role that aligns with its original C0
semantic -- substitution.


---

## Escaping (DLE)

DLE (0x10) escapes the next byte as literal data, not a control code.

- A literal 0x1E in a value: `[DLE][0x1E]`
- A literal DLE in a value: `[DLE][DLE]`

DLE was chosen over ESC (0x1B) to avoid conflict with ANSI escape sequences.


---

## Document Termination (EOT)

EOT (0x04) marks the end of a complete C0DATA document. Optional in
file-at-rest scenarios (EOF is implicit). Useful for streaming, where
multiple documents may be sent over a single connection.


---

## Consistent Roles Across Shapes

The separator codes maintain consistent meaning across all data shapes:

| Shape      | RS means          | US means                  |
|------------|-------------------|---------------------------|
| Tabular    | row               | field / column            |
| Document   | paragraph / block | list item / element       |
| Key-Value  | entry             | key → value               |
| Diff       | --                | anchor ↔ replacement unit |


---

## Data Shape Mapping

How C0DATA maps to and from JSON/YAML/CSV.

### Tabular → JSON

```
␝users
  ␁name␟amount
  ␞Alice␟100
  ␞Bob␟200
```

```json
{"users": [{"name": "Alice", "amount": "100"}, {"name": "Bob", "amount": "200"}]}
```

```csv
name,amount
Alice,100
Bob,200
```

### Key-Value → JSON

```
␝database
  ␞host␟localhost
  ␞port␟5432
```

```json
{"database": {"host": "localhost", "port": "5432"}}
```

### Multi-field → JSON

```
␝data
  ␞a␟b␟c
  ␞d␟e␟f
```

```json
{"data": [["a", "b", "c"], ["d", "e", "f"]]}
```

### Nested → JSON

```
␝users
  ␁name␟address
  ␞Alice␟␂␁street␟city␞123 Main␟Springfield␃
```

```json
{"users": [{"name": "Alice", "address": {"street": "123 Main", "city": "Springfield"}}]}
```

### Document → JSON

```
␜mydb
  ␝users
    ␁name
    ␞Alice
  ␝products
    ␁id
    ␞01
```

```json
{"mydb": {"users": [{"name": "Alice"}], "products": [{"id": "01"}]}}
```


---

## Performance

The tokenizer's hot loop is a single comparison: `byte < 0x20`. This makes
C0DATA inherently fast to parse -- single-byte delimiters, zero-copy
friendly, and SIMD-acceleratable.

Benchmark on 10 MB document (Crystal, --release):

```
avg         4.88 ms       2048.0 MB/s
best        4.09 ms       2447.7 MB/s
```


---

## c0fmt CLI

Command-line tool for converting and inspecting C0DATA.

### Build

```sh
crystal build src/c0fmt.cr -o bin/c0fmt --release
```

### Commands

#### import

```
c0fmt import [format] [file]
```

Import CSV, JSON, or YAML into C0DATA compact format.

- **format** -- `csv`, `json`, or `yaml`. Optional: auto-detected from file
  extension (`.csv`, `.json`, `.yaml`, `.yml`) or content sniffing.
- **file** -- input file. Reads stdin if omitted.
- **-o FILE** -- write output to file instead of stdout.
- **-g NAME** -- group name (defaults to filename stem or `data`).

```sh
c0fmt import data.csv                      # auto-detect from extension
c0fmt import csv data.csv                  # explicit format
echo '{"a":1}' | c0fmt import              # sniff stdin (detects JSON)
cat data.csv | c0fmt import csv            # explicit format, stdin
c0fmt import data.json -g mydata           # custom group name
```

#### export

```
c0fmt export <format> [file]
```

Export C0DATA to CSV, JSON, or YAML.

- **format** -- `csv`, `json`, or `yaml`. Required.
- **file** -- input C0DATA file. Reads stdin if omitted.
- **-o FILE** -- write output to file.

```sh
c0fmt import data.csv | c0fmt export json
c0fmt export yaml data.c0
c0fmt export csv data.c0 -o data.csv
```

#### pretty

```
c0fmt pretty [file]
```

Convert C0DATA to pretty-printed Unicode form. Auto-detects whether
input is already pretty or compact.

- **-o FILE** -- write output to file.

```sh
c0fmt pretty data.c0
cat data.c0 | c0fmt pretty
```

#### compact

```
c0fmt compact [file]
```

Convert C0DATA to compact binary form.

- **-o FILE** -- write output to file.

```sh
c0fmt compact pretty.c0 -o data.c0
```

#### validate

```
c0fmt validate [file]
```

Check well-formedness of a C0DATA document. Prints `valid` to stderr
and exits 0, or prints the error and exits 1.

```sh
c0fmt validate data.c0
```

### Pipelines

Commands compose via stdin/stdout:

```sh
# CSV to JSON
c0fmt import data.csv | c0fmt export json

# JSON to pretty C0DATA
c0fmt import config.json | c0fmt pretty

# YAML to compact C0DATA file
c0fmt import settings.yml | c0fmt compact -o data.c0

# Round-trip: CSV → C0DATA → CSV
c0fmt import csv users.csv | c0fmt export csv
```


---

## Crystal API

For the Crystal library API documentation, see the generated
[API docs](../api/index.html).

### Installation

Add to your `shard.yml`:

```yaml
dependencies:
  c0:
    github: trans/c0data
```

```crystal
require "c0"
```
