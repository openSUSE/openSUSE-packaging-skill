# Sample doc for test-refsection.sh

Fixture only — never referenced by the skill. Exercises the three cases the
real references hit: a `##` section with `###` children, two headings sharing a
substring (ambiguity), a bold lead-in paragraph, and a fenced block whose
`# comment` lines must NOT be mistaken for headings.

## Alpha section

Alpha body.

```sh
# not a heading — this is a shell comment inside a fence
## also not a heading
echo alpha
```

### Alpha one

First child.

### Alpha two

Second child.

## Beta section

Beta body — must NOT appear when Alpha is printed.

**Bold lead-in** — this paragraph is the whole match; the line after the blank
line below belongs to Beta, not to the lead-in.

Trailing Beta paragraph.

## Duplicate candidate one

Ambiguity partner.

## Duplicate candidate two

Ambiguity partner.

### --dash-flag looks like an option to argparse

A section whose name starts with `-` must still be queryable.
