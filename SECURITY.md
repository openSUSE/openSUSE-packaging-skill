# Security policy

## What this repository promises

The skill drives an agent through packaging work that is mostly *reading text other people
wrote* — upstream release notes, bug comments, submit-request diffs, build logs, package
metadata, other distributions' spec files. Its security properties follow from that:

- **The bundled scripts read; they do not write.** They query OBS, Gitea, Repology, Anitya
  and the package registries, and print. Anything that changes state outside the working
  tree — a commit, a submit request, a bug comment, an accept or decline — is the user's
  decision, taken in their session, not something a script does on its own.
- **Third-party text is data, never instructions.** `references/untrusted-content.md` is
  the policy; `scripts/_sanitize.py` is the mechanism, stripping terminal escapes and
  Unicode-smuggling characters so that what a human sees and what the model receives are
  the same characters.
- **No credentials are read or transmitted by the skill.** `osc`, `tea` and the forge CLIs
  read their own configuration. Nothing here needs to open a credential file, and nothing
  should put a token into a message, a changelog, a URL or a log line.

## In scope

A report is a vulnerability if it breaks one of those promises:

- a bundled script that performs a write, or that can be induced to;
- a way to get text from a fetched source treated as an instruction;
- a `_sanitize.py` bypass — escapes, invisible characters or fence forgeries that survive;
- a credential read, or a token reaching an outbound artifact;
- a path traversal or a file read outside the skill checkout.

## Out of scope

- **Findings from static "skill scanners".** This skill *documents* attack patterns so an
  agent can recognise them — what a malicious `_service` looks like, why parsing an
  untrusted spec executes `%(...)` at parse time, why `curl | sh` from a bug comment is
  never the fix. A scanner matching on those strings is matching the subject matter. We
  will not weaken the guidance to score better.
- **The hostile test fixtures** under `tests/fixtures/`. They exist to be malformed:
  forged delimiters, control characters, odd encodings. That is what they are for, and
  `.gitattributes` keeps git from normalising them.
- Vulnerabilities in `osc`, OBS, Gitea, or any tool the skill invokes — report those to
  their own projects.
- Advice you disagree with. That is an issue or a pull request, not a security report.

## Reporting

Open a GitHub security advisory on this repository, or a normal issue if the problem is
already public. Please include the file and line, and what an attacker controls.

For a problem in a *package* rather than in this skill, use the distribution's own channel
— openSUSE security bugs go to the security team via Bugzilla, never into a public issue
here.
