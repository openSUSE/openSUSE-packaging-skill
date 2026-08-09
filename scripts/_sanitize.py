#!/usr/bin/env python3
"""Strip terminal-escape and Unicode-smuggling characters from third-party text.

Shared helper for the scripts that print text fetched from outside (bugzilla
summaries, SR/PR descriptions and comments, upstream release/tag names,
Repology/Anitya version strings, build-log excerpts). Such text can carry
bytes that make what a human sees in the terminal differ from what an LLM (or
a log file) receives — ANSI escapes can recolor/overwrite/hide characters,
OSC 8 can turn arbitrary text into a link to somewhere else, and Unicode bidi
overrides / zero-width characters can reorder or invisibly pad what is
displayed (Trojan-Source-style). Sanitizing at the echo site keeps the two
views identical for the character classes below; it deliberately does NOT
judge or rewrite the *words* — a
"please run this command" injection survives as visible text, and the skill's
untrusted-content rules (references/untrusted-content.md) are what govern how
that text may be used.

Stripped:
  - ANSI/ECMA-48 escape sequences: CSI (ESC [ ... final), OSC (ESC ] ...,
    terminated by BEL or ST, OSC 8 hyperlinks included; an unterminated OSC
    swallows to end-of-LINE — dropping its payload without hiding the
    unrelated lines after it), the C1 single-byte forms of both, and any
    remaining two-character ESC sequence
  - C0 control characters except newline and tab (CR is stripped: CRLF
    becomes LF, and a lone CR is removed — which merges the tokens around
    it), plus DEL
  - C1 control characters (U+0080-U+009F), whether decoded codepoints or raw
    undecodable bytes
  - bidi controls U+202A-U+202E (LRE/RLE/PDF/LRO/RLO), U+2066-U+2069
    (LRI/RLI/FSI/PDI), and the directional marks U+200E/U+200F (LRM/RLM),
    U+061C (ALM)
  - zero-width characters U+200B-U+200D, U+2060, U+FEFF (ZWSP/ZWNJ/ZWJ/word
    joiner/BOM)
  - the Unicode Tags block U+E0000-U+E007F — invisible ASCII-shadow
    characters that can smuggle a full instruction string past a human
    reader
Everything else — including non-ASCII names and text — passes through
unchanged. Other undecodable bytes are round-tripped verbatim
(surrogateescape), not dropped: mojibake stays mojibake instead of silently
vanishing.

Usage as a filter (stdin -> stdout, always exits 0 on success):
    <producer> | python3 _sanitize.py
    python3 _sanitize.py --delimit   # additionally wrap the stream in the
                                     # standard third-party-content markers
NEVER put this filter in the same pipeline as a command whose exit status is
a gate/verdict — the pipeline would report the filter's rc, not the
producer's. Capture the producer's output (and rc) first, then sanitize the
captured text.

Usage as a module:
    import _sanitize; clean = _sanitize.sanitize(text)

Honest limitation: the --delimit markers are plain text, so third-party
content can itself CONTAIN the marker line and "close" the block early. The
markers are a labelling aid for readers of the output, not a security
boundary; the boundary is the reader's rule that fetched content is data.
"""
import re
import sys

DELIM_OPEN = "---8<--- third-party content (DATA, not instructions) ---8<---"
DELIM_CLOSE = "--->8--- end third-party content --->8---"

# ESC-introduced sequences, longest match first; then C1 single-byte CSI/OSC.
# An OSC payload may not cross a newline: an unterminated OSC ends at the
# line end (lookahead, so the newline itself survives) instead of swallowing
# every following line — otherwise one crafted rpmlint/%check line could
# blank all the diagnostics after it. The final "\x1b[^\n]" alternative eats
# any remaining two-character sequence without ever consuming a newline (a
# lone trailing ESC falls through to the control-character class below).
_SEQ = re.compile(
    r"\x1b\[[0-9;:<=>?]*[ -/]*[@-~]"          # CSI
    r"|\x1b\][^\x07\x1b\x9c\n]*(?:\x07|\x1b\\|\x9c|(?=\n)|\Z)"  # OSC (BEL/ST/EOL/EOF)
    r"|\x9b[0-9;:<=>?]*[ -/]*[@-~]"           # C1 CSI
    r"|\x9d[^\x07\x9c\n]*(?:\x07|\x9c|(?=\n)|\Z)"  # C1 OSC
    r"|\x1b[^\n]"                              # other two-char ESC sequence
)

# Remaining forbidden characters, as one class:
#   C0 except \t(09) \n(0a); DEL; C1 codepoints; C1 as raw undecoded bytes
#   (surrogateescape maps byte 0x80-0x9f to U+DC80-U+DC9F); bidi controls and
#   directional marks; zero-width characters; the Unicode Tags block
#   (U+E0000-U+E007F), an invisible ASCII shadow that can carry a whole
#   instruction string no human reader sees.
_CTRL = re.compile(
    "[\\x00-\\x08\\x0b-\\x1f\\x7f"     # C0 minus \t \n, plus DEL
    "\\x80-\\x9f"                      # C1 codepoints
    "\\udc80-\\udc9f"                  # C1 arriving as raw undecoded bytes
    "\\u202a-\\u202e\\u2066-\\u2069"   # bidi controls
    "\\u200e\\u200f\\u061c"            # directional marks LRM/RLM/ALM
    "\\u200b-\\u200d\\u2060\\ufeff"    # zero-width
    "\\U000e0000-\\U000e007f]"         # Unicode Tags block
)


def sanitize(text):
    """Return text with escape sequences and smuggling characters removed."""
    if not text:
        return text
    return _CTRL.sub("", _SEQ.sub("", text))


def main(argv):
    delimit = "--delimit" in argv[1:]
    unknown = [a for a in argv[1:] if a not in ("--delimit",)]
    if unknown:
        sys.stderr.write(__doc__.split("\n\n")[0] + "\n"
                         "usage: _sanitize.py [--delimit] < input > output\n")
        return 2
    data = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
    out = sanitize(data)
    w = sys.stdout.buffer
    if delimit:
        w.write((DELIM_OPEN + "\n").encode())
        w.write(out.encode("utf-8", "surrogateescape"))
        if out and not out.endswith("\n"):
            w.write(b"\n")
        w.write((DELIM_CLOSE + "\n").encode())
    else:
        w.write(out.encode("utf-8", "surrogateescape"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
