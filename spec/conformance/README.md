# C0DATA Conformance Vectors

Language-agnostic golden fixtures for the C0DATA spec, the normative
companion to DESIGN.md's "Canonical Form" section. Every implementation
(Crystal, Go, JS, Rust, …) should consume these files verbatim; a codec
that passes them is conforming, and two conforming codecs produce
identical bytes for the same data — the property content addressing
depends on.

## Encoding conventions

- **Buffers** (`bytes`, `canonical`, `blocks[]`) are lowercase hex
  strings of compact-form bytes.
- **Field values** are either a JSON string (the value's bytes are its
  UTF-8 encoding; control characters appear as ``-style escapes)
  or `{"hex": "..."}` for values that are not valid UTF-8. Either way
  the expected value is the **logical** value — DLE escapes decoded.
- Every file has a `version` and a `cases` array; every case has a
  unique `name` and a human `desc`.

## Files

### decode.json

Compact bytes → expected structure. Case shape:

```json
{
  "name": "...", "desc": "...",
  "bytes": "<hex>",
  "file": "dbname" | null,
  "groups": [
    {"name": "users", "headers": ["a", "b"] | null,
     "records": [["field", {"hex": "00"}], ...]}
  ]
}
```

A single group with `"name": ""` and `"file": null` means the buffer is
a bare record stream (no FS/GS preamble). Expected records follow the
contract exactly: N separators = N+1 fields; an empty record is one
empty field; ETB commit markers and payloads are tolerated framing and
never appear in names, headers, or fields.

### encode.json

Logical structure → expected canonical bytes. Case shape:

```json
{
  "name": "...", "desc": "...",
  "build": {"file": "db" | null,
            "groups": [{"name": "g", "headers": [...] | null,
                        "records": [[...]]}]},
  "canonical": "<hex>"
}
```

A conforming encoder MUST produce exactly `canonical`: minimal escaping
(every value byte < 0x20 escaped with DLE, nothing else escaped), order
preserved, no framing bytes.

### canonical.json

Canonicality classification. Case shape:

```json
{"name": "...", "desc": "...", "bytes": "<hex>",
 "wellformed": true, "canonical": false}
```

`wellformed` — the bytes tokenize without error. `canonical` — the
bytes are a canonical document unit (well-formed, minimally escaped,
no ETB/EOT framing).

### invalid.json

Bytes that MUST be rejected: `{"name", "desc", "bytes"}` — tokenizing
raises (unassigned control code, or DLE at end of input).

### stream.json

Stream-mode (ETB commit) semantics. Case shape:

```json
{"name": "...", "desc": "...", "bytes": "<hex>",
 "committed_end": 6, "torn": false,
 "blocks": ["<hex>", ...],
 "records": [[...]] }
```

`committed_end` — offset just past the last ETB and its payload.
`torn` — uncommitted bytes trail the last commit. `blocks` — each
committed block's bytes (previous commit to ETB, marker and payload
excluded). `records` (optional) — logical records of the committed
region.
