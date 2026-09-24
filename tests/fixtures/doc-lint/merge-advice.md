# Merge-advice probe for tests/test-doc-lint.sh

A line ending in the flag comment must be reported, every other line must not.

Merge it with `tea pr merge --repo pool/foo 3`. <!-- flag -->
Or run `tea pulls merge 3` from the clone. <!-- flag -->
A devel-project PR: `tea pr merge 2 --repo AI/mistral-vibe`.

```
# Wrong forms -- a comment in a fence, not a heading
git-obs pr merge pool/foo#3 <!-- flag -->
```

## Wrong forms

- `tea pr merge --repo pool/foo 3` on your own Leap PR → never.

### A subsection of the wrong forms

- `tea pulls m 3` → never.

## After the wrong forms

Then `curl -X POST https://src.opensuse.org/api/v1/repos/pool/foo/pulls/3/merge`. <!-- flag -->
