# C0DATA Specification (Draft)

C0DATA is a data system built on ASCII C0 control codes. It provides concise,
structured representation for common data forms — tabular data, hierarchical
documents, diffs, configuration — using single-byte control codes as delimiters
and UTF-8 text for values.

It sits between human-readable text formats (JSON, YAML, TOML) and opaque
binary formats (protobuf, msgpack). Values remain plain text. Structure is
expressed through control bytes — compact, zero-copy friendly, and inspectable
with minimal tooling.


## Design Principles

- Preserve the original semantics of C0 control codes where possible.
- Only assign codes that genuinely earn their place — leave the rest reserved.
- Support both self-describing (schemaless) and positional (schema-based) usage.
- One control code vocabulary, multiple data shapes (table, document, diff, etc.).
- Structure is determinable with **bounded lookbehind**. Chunked scanning,
  SIMD acceleration, and mid-buffer resynchronization depend on this; no
  feature may require unbounded context to classify a byte.


## Assigned Control Codes

| Byte | Hex  | Abbr | C0DATA Role                                  |
|------|------|------|----------------------------------------------|
| 0x01 | 0x01 | SOH  | Header (declares field names for a group)     |
| 0x02 | 0x02 | STX  | Open nested sub-structure / reference scope   |
| 0x03 | 0x03 | ETX  | Close nested sub-structure / reference scope  |
| 0x04 | 0x04 | EOT  | End of document / message                     |
| 0x05 | 0x05 | ENQ  | Reference (enquiry — look up named data)      |
| 0x10 | 0x10 | DLE  | Escape (next byte is literal, not control)    |
| 0x17 | 0x17 | ETB  | Commit marker (stream mode block terminator)  |
| 0x1A | 0x1A | SUB  | Substitution (old → new, used in C0-DIFF)     |
| 0x1C | 0x1C | FS   | File / Database separator                     |
| 0x1D | 0x1D | GS   | Group / Table / Section separator             |
| 0x1E | 0x1E | RS   | Record / Row separator                        |
| 0x1F | 0x1F | US   | Unit / Field separator                        |

All other C0 codes (0x00–0x1F) are currently **reserved**.


## Structural Hierarchy

The four separator codes form a fixed semantic hierarchy:

    FS  >  GS  >  RS  >  US
    file   group  record  field

- **FS (0x1C)** — Top-level container. A database, a file, a document.
- **GS (0x1D)** — A group within a file. A table, a collection, a section.
- **RS (0x1E)** — A record within a group. A row, an entry, a block.
- **US (0x1F)** — A unit within a record. A field, a property, an element.

Text immediately following FS or GS is the **label** (name) for that scope.


## Two Forms: Compact and Pretty

C0DATA has two representations of the same data.

### Compact Form (Canonical)

The wire/storage format. A continuous byte stream. Every byte between control
codes is literal data — including LF, CR, HT, and spaces. No whitespace is
ignored. This is the canonical form.

    [FS]mydb[GS]users[SOH]name[US]amount[RS]Alice Smith[US]1502.30[RS]Bob[US]340.00

### Pretty Form (Human-Readable)

For human inspection and documentation. Uses Unicode Control Pictures
(U+2400 block) for visible glyphs. Whitespace rules:

- LF and CR are ignored (formatting only).
- Whitespace (spaces, tabs) adjacent to control codes is trimmed.
  This allows indentation and spacing for readability.
- Spaces between non-whitespace data characters are preserved
  (e.g., "Alice Smith" keeps its space).
- Inside STX/ETX (␂...␃), all content is preserved verbatim —
  no trimming. This allows STX/ETX to serve as quoting for values
  with significant leading/trailing whitespace.

Example:

    ␜mydb
      ␝users
        ␁name␟amount
        ␞Alice Smith␟1502.30
        ␞Bob␟340.00

To include a literal LF or CR in a value, DLE-escape it: `[DLE][LF]`.

Quoting with STX/ETX:

    ␞␂  leading spaces  ␃␟normal value

A `c0fmt` tool can convert between compact and pretty forms.


## Self-Describing Data (SOH Headers)

When SOH (0x01) appears at the start of a group, it declares field names.
Records that follow are positional against those names — like a CSV header row.

    [GS]users
    [SOH]name[US]amount[US]type
    [RS]Alice[US]1502.30[US]DEPOSIT
    [RS]Bob[US]340.00[US]WITHDRAWAL

Without SOH, data is purely positional (schema known by both sides):

    [GS]
    [RS]Alice[US]1502.30[US]DEPOSIT
    [RS]Bob[US]340.00[US]WITHDRAWAL

**Convention:** When no schema is provided, the first field of a record is
assumed to be its `id`.


## Nested Structures (STX/ETX)

When a field value is itself structured, wrap it in STX/ETX. Inside the
brackets, the separator hierarchy resets — codes are scoped to the
sub-structure.

    [GS]
    [SOH]name[US]amount[US]address
    [RS]Alice[US]1502.30[US][STX]
      [SOH]street[US]city
      [RS]123 Main[US]Springfield
    [ETX]
    [RS]Bob[US]340.00[US][STX]
      [SOH]street[US]city
      [RS]456 Elm[US]Shelbyville
    [ETX]

STX/ETX can nest within themselves for arbitrary depth.

Arrays are simply US-separated values inside STX/ETX:

    [RS]Alice[US][STX]Admin[US]Editor[US]User[ETX][US]1502.30


## References (ENQ)

ENQ (0x05) marks a field value as a reference to data defined elsewhere.
Referenced material must be defined **before** any reference to it (enabling
single-pass parsing with no backtracking).

**Simple reference** (entire group):

    [ENQ]tags

Terminated by the next control code. Looks up the group labeled `tags`.

**Path reference** (record or field within a group):

    [ENQ][STX]tags[US]001[US]label[ETX]

STX/ETX scopes the reference. US separates path segments:
group → record id → field name.

### Example

    [GS]tags
    [SOH]id[US]label
    [RS]001[US]Admin
    [RS]002[US]Editor
    [RS]003[US]User

    [GS]articles
    [SOH]title[US]tags[US]body
    [RS]My Post[US][ENQ]tags[US][ENQ][STX]article[US]001[ETX]


## Document Mode (Depth via GS Repetition)

For hierarchical documents (like Markdown headings), GS can be repeated to
indicate depth level:

    [GS]         = level 1   (like #)
    [GS][GS]     = level 2   (like ##)
    [GS][GS][GS] = level 3   (like ###)
    ...

Within a section, RS marks a content block (paragraph) and US marks
sub-elements (list items) within that block.

Example:

    [FS]My Document
    [GS]Chapter 1
    [RS]First paragraph of chapter one.
    [RS]Second paragraph.
    [GS][GS]Section 1.1
    [RS]Some content here.
    [RS]A list of items:
    [US]First item
    [US]Second item
    [US]Third item
    [GS][GS]Section 1.2
    [GS][GS][GS]Subsection 1.2.1
    [RS]Deep content.
    [GS]Chapter 2
    [GS][GS]Section 2.1
    [RS]And so on.


## Key-Value Configuration

For configuration data (like TOML or INI), each RS is an entry with the
first field as the key and the second as the value. No SOH header needed.

    [GS]database
    [RS]host[US]localhost
    [RS]port[US]5432
    [GS]server
    [RS]host[US]0.0.0.0
    [RS]port[US]8080

Nested values use STX/ETX or ENQ references:

    [RS]allowed_origins[US][STX]localhost[US]example.com[US]api.example.com[ETX]


## Consistent Roles Across Shapes

The separator codes maintain consistent meaning across all data shapes:

| Shape      | RS means          | US means                  |
|------------|-------------------|---------------------------|
| Tabular    | row               | field / column            |
| Document   | paragraph / block | list item / element       |
| Key-Value  | entry             | key → value               |
| Diff       | —                 | anchor ↔ replacement unit |


## Escaping (DLE)

DLE (0x10) escapes the next byte as literal data, not a control code.

- A literal 0x1E in a value: `[DLE][0x1E]`
- A literal DLE in a value: `[DLE][DLE]`

DLE was chosen over ESC (0x1B) to avoid conflict with ANSI escape sequences.

DLE is the format's one concession against pure statelessness: classifying
a control byte mid-buffer requires checking for a preceding escape, and a
run of DLEs requires counting its parity. That lookbehind is **bounded**
by the length of the escape run — the minimum possible price for an
in-band escape, and the price is what buys byte-transparent values
(including literal LF, HT, and raw binary if a consumer wants it). This
is the scan invariant the design principles protect; it is why the
length-prefixed binary idea was rejected (see Speculations).


## Canonical Form (Content Addressing)

The compact form is canonical in the strong sense: **the same logical
value encodes to exactly one byte sequence**, reproducible by any
conforming encoder in any language. Two conforming encoders given the
same data MUST emit identical bytes, so the bytes may be hashed and
equal hashes mean equal values. The pretty form is presentation, never
hashed. The rules:

### Minimal Escaping

A canonical encoder emits DLE if and only if the next byte would
otherwise be read as a control code: **every value byte below 0x20 is
escaped; no byte at or above 0x20 is ever escaped.** Gratuitous escapes
(`[DLE]A` for `A`) are non-canonical. The escape set is frozen at "all
bytes below 0x20" — not "currently assigned codes" — so future code
assignments can never change what is minimal and silently break
existing hashes.

### Fields Are Counted by Separators

N separators delimit N+1 units: `Alice[US]` is two fields (the second
empty) and is a different value from `Alice` (one field). An empty
record (RS immediately followed by a structural code) is one empty
field. There is no "absent" field — only empty — and arity is always
significant. Because decoding is exact, no encoder restriction is
needed: every distinct field sequence already has exactly one encoding.

### Values Are Byte Sequences

Field values are byte-transparent: conventionally UTF-8 text, but any
bytes are legal (control bytes escaped per the rule above). A canonical
encoder performs **no Unicode normalization** and no other
transformation of value bytes. "Same logical value" means "same bytes,
field by field."

### Names Are Identifiers

Labels — file and group names — and SOH header names are identifiers,
not values: they MUST NOT contain bytes below 0x20, escaped or
otherwise. (Escaped control bytes in names would buy little and
complicate every name scan; identifiers stay plain.)

### Order Is Significant

C0 defines **no unordered constructs**. Records appear in order; fields
are positional; SOH header columns are positional. Conforming codecs
MUST preserve order exactly and MUST NOT reorder. Canonicalizing
logically unordered data — a map's keys, a set's members, a directory's
entries — into a definite order is the **producer's responsibility**,
above the format (compare git tree objects or RFC 8785 for JSON: the
sort rule belongs to the application's data model, not the wire
format). Where no domain rule exists, the recommended convention is to
sort records byte-lexicographically by first field.

### Framing Is Outside the Hash

ETB commit markers and their payloads, and EOT, are framing — never
part of any canonical unit's bytes.

### Canonical Units

Hashing requires agreement on the byte span. Three granularities:

- **Record** — the content bytes after its RS, up to the next
  structural code or framing byte. Escapes and STX/ETX nesting
  included, the RS itself excluded.
- **Group** — from its GS through its records (name and SOH header
  included), up to the next top-level GS, FS, or EOT.
- **Document** — the buffer from FS (or start of content) to the last
  content byte. A canonical document contains no framing bytes at all:
  no ETB (that is stream framing) and no trailing EOT (that is
  transport framing).

For stream logs, the hashed span of a **block** is defined in Stream
Mode and equals the framing block exactly.

The contract is only credible across implementations with shared golden
fixtures — the language-agnostic conformance suite is the normative
companion to this section.


## Document Termination (EOT)

EOT (0x04) marks the end of a complete C0DATA document or message. Optional
in file-at-rest scenarios (EOF is implicit). Useful for streaming, where
multiple documents may be sent over a single connection.


## Stream Mode (ETB Commits)

C0DATA records are start-delimited: RS begins a record, and nothing marks
its end except the next control code or end of input. For a document at
rest that is fine. For an append-only log — an event stream, a write-ahead
log, a journal — it is not: a process can crash mid-append, and with
start-delimiters alone a truncated final record is indistinguishable from a
complete one. EOT does not help; a crashed append never reaches it.

Stream mode closes this gap with **ETB (0x17)** — "End of Transmission
Block" — as an explicit commit marker.

### The Commit Rule

ETB commits the **block** of bytes appended since the previous ETB (or the
start of the stream). A block is typically one record, but may be several
— committing N records with a single trailing ETB makes the batch atomic:
either the whole batch replays, or none of it does.

    [RS]create[US]a1b2c3[US]1718208000[ETB]
    [RS]name[US]draft-2[US]1718208042[ETB]
    [RS]tag[US]alpha[US]17182080        ← torn tail: no ETB, skipped

In stream mode:

- A block is **complete** if and only if it is terminated by ETB.
- **Readers** MUST treat a trailing block with no terminating ETB as torn
  and skip it. It is residue of an interrupted append, not data.
- **Writers** MUST verify the stream ends at an ETB before appending — by
  truncating an uncommitted tail or by appending from the last ETB
  position. Appending after an unrepaired tail is non-conforming, and not
  merely untidy: a tail torn between a DLE and its escaped byte ends in a
  bare DLE, which would escape the RS of the next blind append and fuse
  the torn fragment with the new record into one well-formed, committed —
  and corrupt — block.
- A block and its ETB SHOULD be issued as a single append, so that ETB
  never lands without its block.

The commit rule applies to every appended unit, including an SOH header —
a header write can tear exactly like a record write.

### ETB Payload

ETB may be followed by an **integrity payload**, terminated by the next
control code. An empty payload means the ETB is framing-only. Payload
semantics (e.g. a checkpoint hash of the preceding block — see
Speculations) are not yet specified, but the grammar is fixed now so that
framing-only readers remain forward-compatible: skip to the next control
code after ETB.

When payload semantics are specified, the hashed **span** is the block
exactly as framing defines it: every byte after the previous ETB's
payload (or from the start of the stream) up to but not including this
ETB — leading RS and any GS/SOH preamble bytes included, the ETB marker
and payload excluded. Defining the span to the byte is part of the
canonical-form contract (see Canonical Form).

### Relationship to the Rest of C0DATA

ETB is framing, not data. It and its payload are not part of any record's
bytes — a record's content is identical whether or not it travels with a
commit marker. (This matters when records are hashed; see Open Questions
on canonical form.)

Outside stream mode, parsers MUST tolerate a framing-only ETB as a no-op
at any record boundary. This keeps a stream-mode log readable by ordinary
C0DATA tooling — pretty-printing, validation, export — without a special
mode. In pretty form, ETB renders as ␗ (U+2417).

### What Stream Mode Does Not Provide

ETB commits give **crash consistency**: an interrupted append is always
detectable and recoverable, never silently folded into state. They do not
provide **durability** (when bytes reach disk is the application's fsync
discipline) or **integrity** (bit rot or zero-fill inside a committed
block goes undetected until checkpoint-hash payloads are specified).


## C0-DIFF (Atomic Multi-File Edits)

C0-DIFF is a control-code markup format for atomic multi-file edits. It uses
sequential anchored patterns — literal text acts as anchors that must match
exactly once, and SUB-delimited regions mark the actual replacements.

### Diff Control Codes

| Code | Hex  | Name           | Purpose                                            |
|------|------|----------------|----------------------------------------------------|
| FS   | 0x1C | File Separator | Starts a new file block (followed by file path)    |
| GS   | 0x1D | Group Sep.     | Starts a new section/pattern within a file         |
| US   | 0x1F | Unit Separator | Separates pattern units (anchor ↔ replacement)     |
| SUB  | 0x1A | Substitute     | Separates old text from new text (old [SUB] new)   |
| DLE  | 0x10 | Data Link Esc  | Escapes literal control codes (next byte is literal)|

### Format

    [FS]<filepath>[GS]<literal>[US]<old>[SUB]<new>[US]<literal>

US separates the units of the pattern — anchor text from replacement regions.
SUB is the substitution operator within a replacement — old [SUB] new.

### Example

    [FS]foo.txt
    [GS]Hello [US]world[SUB]universe[US]!

This means: In file `foo.txt`, find the pattern `Hello world!` and replace
`world` with `universe`, yielding `Hello universe!`.

Sections within a file are sequential anchored patterns. Literal text between
replacement regions must match exactly once in the file and serves as context
anchors. Multiple files can be edited in a single C0-DIFF document. All files
are validated before any writes happen (atomic rollback semantics).

### Relationship to C0DATA

C0-DIFF shares the same control code vocabulary as C0DATA. FS and GS retain
their structural meanings (file boundary, section/group boundary). US retains
its role as a unit-level separator. DLE is the same escape mechanism used
throughout C0DATA. SUB takes on a diff-specific role that aligns with its
original C0 semantic — substitution.


## A Full Example (Database)

    [FS]mydb
    [GS]users
    [SOH]name[US]amount[US]type
    [RS]Alice[US]1502.30[US]DEPOSIT
    [RS]Bob[US]340.00[US]WITHDRAWAL
    [GS]products
    [SOH]id[US]product[US]qty
    [RS]01[US]Widget[US]100
    [RS]02[US]Gadget[US]250
    [EOT]


## Data Shapes

C0DATA is a system, not a single format. The same control code vocabulary
expresses multiple common data shapes:

| Shape      | Primary Codes Used          | Analogous To         |
|------------|-----------------------------|----------------------|
| Tabular    | FS, GS, SOH, RS, US        | CSV, SQL results     |
| Document   | FS, GS×N, RS, US           | Markdown, outlines   |
| Key-Value  | GS, SOH, RS, US            | TOML, INI            |
| Nested     | STX/ETX, any inner codes   | JSON objects         |
| Reference  | ENQ, STX/ETX for paths     | foreign keys, links  |
| Diff       | FS, GS, US, SUB, DLE       | unified diff, patches|
| Stream     | RS, US, ETB; EOT between docs | NDJSON, SSE, WAL  |


## Open Questions

- **Unassigned codes:** Should a parser reject, ignore, or pass-through
  unassigned C0 bytes in compact form?
- **C0-DIFF integration:** SUB is used in diff mode but not in data mode.
  Any conflicts if both modes coexist in one document?
- **Reserved codes:** CAN, ESC, and others may find roles as the spec
  evolves.


## Speculations

The following ideas are not part of the spec. They explore how remaining
reserved codes might be used if these features are needed in the future.

### Checkpoint Hashes (Integrity Verification)

ETB (0x17) is now assigned as the stream-mode commit marker, and its
payload grammar is reserved (see Stream Mode). The speculation that
remains: the payload could carry a **hash of the preceding block**, so a
receiver verifies integrity at each checkpoint, not just truncation at
the tail. Useful for large documents or unreliable transports.

    [GS]users
    [SOH]name[US]amount
    [RS]Alice[US]1502.30
    [RS]Bob[US]340.00
    [ETB]<hash>

Design constraints already settled with a real consumer (transfs):

- **Integrity, not security.** Checkpoint hashes detect corruption and
  truncation; tamper-evidence belongs to the layers above (content
  addressing, signatures). A fast non-cryptographic hash would suffice
  functionally.
- **Algorithm-tagged.** The payload should carry a small algorithm tag
  (algo-id ‖ length ‖ digest, multihash-style) rather than pinning one
  hash family, so cheap integrity-only consumers and SHA-256-everywhere
  consumers both fit, and digest length stays future-proof.
- **Blocks are independent — no hash chaining.** A consumer that wants a
  tamper-evident chain includes the previous hash as a field in its own
  records, at its own semantic layer, invisible to C0.
- **Span is the framing block** (see Stream Mode), defined to the byte
  together with the canonical-form contract.

The payload encoding is **text** (hex digest, with the algorithm tag as
a short text prefix). Raw digest bytes would violate "payload terminated
by the next control code" and were rejected along with SO/SI binary
fields (below). Text costs 2× on the digest but keeps the framing
invariant and forward compatibility for framing-only readers.

**CAN (0x18)** — "Cancel" — could signal that the preceding data is invalid
and should be discarded. A natural response when a checkpoint hash fails.

### Binary Data (SO/SI) — REJECTED

The idea: **SO (0x0E) / SI (0x0F)** — "Shift Out / Shift In" — shift into
binary mode with a length prefix, read exactly N raw bytes with no
control-code scanning, shift back:

    [RS]image-001[US][SO]<4-byte length><raw bytes>[SI]

**Rejected** because it breaks the bounded-lookbehind invariant (see
Design Principles): a byte inside an SO region is indistinguishable from
structure without having parsed from the beginning, which forecloses
chunked scanning, SIMD, and resynchronization — and a single corrupted
length byte desyncs everything after it. C0 is not a blob format.

Binary values that fit in fields ride as text (hex/base64 — a 32-byte
digest is 64 hex bytes) or as DLE-escaped raw bytes (~12.5% average
inflation, in-spec today, scan-safe). Large blobs belong out-of-line,
addressed by name or hash — content-addressed stores do exactly this.

The one shape that could ever work without breaking the invariant: a
**blob appendix after EOT**. The scanner stops at EOT, so raw bytes
beyond it are never scanned; a regular group inside the document could
declare (name, offset, length) entries pointing into the appendix. If a
real consumer with in-line blob needs ever appears, that is the design
to explore — likely as a separate C0BLOB spec, not core C0. (YAML
reached the same conclusion from a different direction: its `!!binary`
type is base64 text, never raw bytes.)

### Type Discrimination (Numbers vs Text)

Currently all values are text. If type information is needed, several
approaches are possible:

**Schema-level typing** — SOH header declares types alongside names using
a separator convention:

    [SOH]name:s[US]amount:n[US]qty:i

Where `s` = string, `n` = number, `i` = integer, etc.

**Value-level prefix** — A reserved code before a value signals its type.
Candidates include the DC codes (DC1–DC4, 0x11–0x14) which were originally
"device control" — they could become "data class" indicators:

    [RS]Alice[US][DC1]1502.30[US][DC1]42

Where DC1 means "this value is numeric."

**Convention** — The application decides, like how JSON numbers are simply
unquoted text. The format stays type-agnostic.


## Original C0 Control Code Reference

| Dec | Hex  | Abbr | Name                 | Original Purpose                                    |
|-----|------|------|----------------------|-----------------------------------------------------|
| 0   | 0x00 | NUL  | Null                 | Filler / do nothing                                 |
| 1   | 0x01 | SOH  | Start of Heading     | Beginning of message header                         |
| 2   | 0x02 | STX  | Start of Text        | End of header, start of body                        |
| 3   | 0x03 | ETX  | End of Text          | End of message body                                 |
| 4   | 0x04 | EOT  | End of Transmission  | Transmission complete                               |
| 5   | 0x05 | ENQ  | Enquiry              | Request identification / status                     |
| 6   | 0x06 | ACK  | Acknowledge          | Confirm correct receipt                             |
| 7   | 0x07 | BEL  | Bell                 | Alert the operator                                  |
| 8   | 0x08 | BS   | Backspace            | Move cursor back one space                          |
| 9   | 0x09 | HT   | Horizontal Tab       | Move to next tab stop                               |
| 10  | 0x0A | LF   | Line Feed            | Advance to next line                                |
| 11  | 0x0B | VT   | Vertical Tab         | Move to next vertical tab stop                      |
| 12  | 0x0C | FF   | Form Feed            | Eject page / start new page                         |
| 13  | 0x0D | CR   | Carriage Return      | Return to beginning of line                         |
| 14  | 0x0E | SO   | Shift Out            | Switch to alternate character set                   |
| 15  | 0x0F | SI   | Shift In             | Switch back to standard character set               |
| 16  | 0x10 | DLE  | Data Link Escape     | Next character is data, not control                 |
| 17  | 0x11 | DC1  | Device Control 1     | XON (resume transmission)                           |
| 18  | 0x12 | DC2  | Device Control 2     | Device-specific                                     |
| 19  | 0x13 | DC3  | Device Control 3     | XOFF (pause transmission)                           |
| 20  | 0x14 | DC4  | Device Control 4     | Device-specific                                     |
| 21  | 0x15 | NAK  | Negative Acknowledge | Report receive error                                |
| 22  | 0x16 | SYN  | Synchronous Idle     | Maintain timing sync                                |
| 23  | 0x17 | ETB  | End Trans. Block     | End of data block                                   |
| 24  | 0x18 | CAN  | Cancel               | Preceding data invalid                              |
| 25  | 0x19 | EM   | End of Medium        | Physical end of storage                             |
| 26  | 0x1A | SUB  | Substitute           | Replacement for invalid character                   |
| 27  | 0x1B | ESC  | Escape               | Introduces escape sequence                          |
| 28  | 0x1C | FS   | File Separator       | Highest-level data separator                        |
| 29  | 0x1D | GS   | Group Separator      | Second-level data separator                         |
| 30  | 0x1E | RS   | Record Separator     | Third-level data separator                          |
| 31  | 0x1F | US   | Unit Separator       | Lowest-level data separator                         |
| 127 | 0x7F | DEL  | Delete               | Erase character (punch all holes)                   |
