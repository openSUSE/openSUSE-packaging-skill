# OBS API token authentication

Client-side contract for authenticating to the Open Build Service with a
general API token instead of a username and password. The server side is
implemented alongside this contract as a draft in open-build-service
(`Token::APIToken`: `Authorization: Bearer` authentication, SHA256-hashed
secret storage, optional expiry, web UI plus API issuance/revocation —
a draft branch in a fork of open-build-service); this document
fixes what the client — `geectl`, scripts, and agents — must do so both sides
stay aligned.

## Token model

- A general API token is a bearer credential: whoever holds it can act as
  the account that created it, across the whole API.
- It is distinct from the operation-scoped tokens `geectl remote create-token --operation <op> --live` manages
  (`rebuild`, `release`, `service`, `workflow`): those are single-operation
  trigger tokens, not a login replacement, and this document does not change
  them.
- Tokens are created and revoked in the OBS web UI; the client never mints
  them.

## Credential precedence

When authenticating to an apiurl, the first configured source wins:

1. `GEECTL_OBS_APIKEY_<ALIAS>` environment variable — ephemeral, for CI and agents.
2. Username/password (`GEECTL_OBS_USERNAME[_<ALIAS>]`/`GEECTL_OBS_PASSWORD[_<ALIAS>]`, or the `*_FILE` variants) — the legacy path, kept for API instances without
   token support.
3. Interactive prompt — humans only. An agent must never block on it: fail
   with "no OBS credential configured" instead.

The config file holds endpoints only, never credentials: geectl refuses
credential-shaped keys in it. Like the other `GEECTL_*` variables, a token
for a named instance needs that instance's entry in the config file — the
variable supplements the config, it does not replace it. `geectl config show`
reports credential status, never a secret value.

Per-call instance selection is the global `--instance` flag (`geectl --instance=ALIAS ...`): the flag beats the environment and the working-copy state, and credentials resolve from the flagged instance's own env keys only.

## Auth transport

The client sends the token as an HTTP `Authorization: Bearer <token>` header
on every API request. A `401` means the token is invalid or expired: the
client reports it and stops. It must **not** silently fall back to the
password on a token 401 — an invisible downgrade hides a revoked token and
trains the user to keep typing a password.

## Refresh

Tokens may carry an expiry. Where the server issues expiring tokens with a
refresh mechanism, the client refreshes proactively ahead of expiry and
stores the new token back into the source it came from — with one exception:
a token injected via `GEECTL_OBS_APIKEY_<ALIAS>` is never written to disk; the caller
re-injects the fresh value. The refresh endpoint itself is server-side; the
client contract is only: refresh early, update the same store, never persist
an environment-provided token.

## Agent rules

- Never print, log, or echo a token — not in `--debug` output, not in
  transcripts, not in error messages.
- Never pass a token as a command-line argument: it is visible in the
  process list. Environment variable only — never a config file: geectl's config refuses credential-shaped keys.
- A file holding a credential must be mode `0600` and must never be committed
  to any repository.
- Tokens never appear in SR messages, comments, `.changes` entries, commit
  messages, or URLs.
- On suspected exposure: revoke the token in the web UI and generate a new
  one; do not keep using it "just this once".

## Migration

Once the server supports tokens, prefer them over passwords everywhere a
choice exists. Keep the username/password path for API instances that do not
offer tokens yet — do not remove it pre-emptively.
