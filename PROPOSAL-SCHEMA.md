# Proposal: C0 Schema System

**Status:** Draft — open for comment
**Date:** 2026-03-07

## Summary

A schema system for C0DATA that uses C0DATA's own structural vocabulary.
Schemas are C0DATA documents that describe the shape and constraints of
other C0DATA documents. No new control codes are required.

## Motivation

C0DATA currently treats all values as untyped text. This works well for
many use cases, but applications often need:

- **Type safety** — know that a field is an integer before parsing it
- **Validation** — reject malformed data at the boundary
- **Documentation** — describe what a data shape looks like
- **Code generation** — auto-generate serialization from a schema

JSON has JSON Schema. YAML has YAML Schema. Protobuf has `.proto` files.
C0DATA needs something equivalent.

## Design Principles

1. **Schemas are C0DATA** — no new format, no new parser. A schema is
   just another C0DATA document.
2. **No new control codes** — use the existing 11 assigned codes.
3. **Progressive** — untyped data remains valid. Schemas add constraints
   without breaking existing data.
4. **Structural, not textual** — prefer control code semantics over
   text conventions for machine-discoverability.

## Proposal

### Schema Structure

A schema uses C0DATA's document mode. Each field definition is a group,
and its constraints are key-value records within that group. Nested
objects use GS depth (GS×N), exactly like document sections.

```
␝␁user
  ␝name
    ␞type␟s
    ␞req␟true
    ␞min␟1
    ␞max␟255
  ␝age
    ␞type␟i
    ␞min␟0
  ␝email
    ␞type␟s
    ␞req␟true
    ␞pattern␟^[^@]+@[^@]+$
  ␝role
    ␞type␟s
    ␞enum␟␂␟admin␟editor␟viewer␃
  ␝address
    ␞type␟object
    ␞req␟true
    ␝␝street
      ␞type␟s
      ␞req␟true
    ␝␝city
      ␞type␟s
      ␞req␟true
    ␝␝zip
      ␞type␟s
      ␞pattern␟^\d{5}$
  ␝tags
    ␞type␟[s]
    ␞max␟10
```

This reads naturally: the schema for "user" has fields "name", "age",
"email", etc. The "address" field contains sub-fields at the next depth
level, just like subsections in a C0DATA document.

### Schema Marker: SOH after GS

To distinguish schema groups from data groups, a schema group's name
is preceded by SOH (0x01):

```
[GS][SOH]user    ← schema definition for "user"
[GS]users[SOH]...  ← data group with header (existing usage)
```

In pretty form:

```
␝␁user        ← schema group
␝users        ← data group
  ␁name␟age   ← data header (existing)
```

**Why SOH?** It already means "start of heading" — metadata that
declares what follows. A schema is exactly that: a heading that
declares the shape of data. The two uses of SOH are consistent:

| Position | Meaning | Example |
|----------|---------|---------|
| Inside group, after name | Header fields for this group | `␝users␁name␟age` |
| Immediately after GS, before name | This group IS a schema | `␝␁user` |

A parser distinguishes them with a single byte check: after GS, is the
next byte SOH? If yes, it's a schema group. If no, it's a data group.

**Why not a text convention like `@`?** Text conventions require string
matching and are invisible to the structural parser. SOH is a control
code — it's machine-discoverable, unambiguous, and consistent with
C0DATA's philosophy that structure lives in control codes.

### Type Codes

| Code | Meaning | Example value |
|------|---------|---------------|
| `s` | String | `hello` |
| `i` | Integer | `42` |
| `n` | Number (float) | `3.14` |
| `b` | Boolean | `true` / `false` |
| `t` | Timestamp (ISO 8601) | `2026-03-07T12:00:00Z` |
| `[X]` | Array of X | `[s]` = array of strings |
| `object` | Nested object | sub-fields at next GS depth |

### Constraint Fields

| Field | Meaning | Applies to |
|-------|---------|------------|
| `type` | Type code | All |
| `req` | Required (`true`/`false`) | All |
| `min` | Minimum value or length | `i`, `n`, `s`, arrays |
| `max` | Maximum value or length | `i`, `n`, `s`, arrays |
| `pattern` | Regex pattern | `s` |
| `enum` | Allowed values (STX/ETX array) | `s`, `i` |
| `default` | Default value | All |

Constraint fields are extensible — applications can add custom
constraint records without breaking the schema format.

### Schema References (ENQ)

Reusable type definitions use ENQ, C0DATA's existing reference
mechanism:

```
␜schemas
  ␝␁address
    ␝street
      ␞type␟s
      ␞req␟true
    ␝city
      ␞type␟s
      ␞req␟true

  ␝␁user
    ␝name
      ␞type␟s
      ␞req␟true
    ␝address
      ␞type␟␅address
      ␞req␟true
```

This is the C0DATA equivalent of JSON Schema's `$ref`.

### Co-located Schemas and Data

Schemas can live alongside the data they describe:

```
␜mydb
  ␝␁user
    ␝name
      ␞type␟s
      ␞req␟true
    ␝age
      ␞type␟i

  ␝users
    ␁name␟age
    ␞Alice␟30
    ␞Bob␟25
```

The parser sees two groups: `␁user` (schema) and `users` (data).
Schema-unaware parsers simply skip groups whose name starts with SOH.

### Inline Type Hints (Lightweight Alternative)

For simple cases where a full schema is overkill, type suffixes in
SOH headers provide a lightweight option:

```
␝users
  ␁name:s␟amount:n␟qty:i␟active:b
  ␞Alice␟1502.30␟100␟true
```

This is a convention, not a structural feature. The `:` is just text
within the header field name. Parsers that understand the convention
can split on `:` to extract type info. Parsers that don't just see
field names like `name:s`.

This could complement the full schema system rather than replace it.

## Comparison with JSON Schema

The equivalent JSON Schema for the user example above is ~25 lines
of JSON (~580 bytes). The C0 schema is ~24 lines (~210 bytes compact).

| Aspect | JSON Schema | C0 Schema |
|--------|-------------|-----------|
| Format | JSON | C0DATA |
| Nesting | `properties: { properties: {} }` | GS depth (␝␝) |
| References | `$ref: "#/$defs/..."` | ENQ (␅address) |
| Marker | `$` prefix convention | SOH control code |
| Extensibility | Add new keys | Add new records |
| Co-location | Separate file or inline | Same document |

## Open Questions

1. **Schema versioning** — How should schema evolution be handled?
   Version field? Multiple schema groups with version suffixes?

2. **Strict mode** — Should there be an equivalent of JSON Schema's
   `additionalProperties: false`? A constraint like `strict␟true`
   on the schema group itself?

3. **Inline type hints** — Should `name:s` in SOH headers be part
   of the spec or left as application convention?

4. **Union types** — How to express "string or integer"? Perhaps
   `s|i` notation in the type field?

5. **Foreign keys** — ENQ already supports references between groups.
   Should schemas be able to declare foreign key constraints?

6. **Validation API** — What should `C0::Schema.validate(data, schema)`
   return? Boolean? Array of errors? Should validation be streaming?

## Feedback

Comments and questions welcome. Open an issue at
https://github.com/c0data/c0-spec/issues or discuss in the repo.
