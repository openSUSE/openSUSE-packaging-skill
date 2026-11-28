# Bare-log probe for tests/test-doc-lint.sh

A line ending in the flag comment must be reported, every other line must not.

Read it with `geectl local-build log REPO ARCH SPEC`. <!-- flag -->
Or `geectl local-build log --project PRJ REPO ARCH SPEC` for the project.
A log with the flag in another order: `geectl local-build log REPO ARCH SPEC --project PRJ`.
The `geectl local-build log` leaf needs --project (prose, no citation).
