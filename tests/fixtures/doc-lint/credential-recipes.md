# Credential-recipe probe for tests/test-doc-lint.sh

A line ending in the flag comment must be reported, every other line must not.

Read the token with `cat ~/.config/tea/config.yml`. <!-- flag -->
    grep pass ~/.config/osc/oscrc <!-- flag -->
with open(os.path.expanduser("~/.netrc")) as fh: <!-- flag -->
`yaml.safe_load(Path("~/.config/tea/config.yml").expanduser().read_text())` <!-- flag -->
`BUGZILLA_API_KEY="$(cat "$HOME/.config/mcp-bugzilla/api-key")"` <!-- flag -->
curl -H "Authorization: token $(gh auth token)" https://api.github.com <!-- flag -->
openqa-cli api --apikey 0123456789ABCDEF jobs <!-- flag -->
curl -H 'Authorization: Bearer abcdef0123456789' https://src.opensuse.org/api/v1/user <!-- flag -->
git clone https://bob:hunter2hunter2@src.opensuse.org/pool/foo <!-- flag -->

Never read an `oscrc`, `~/.config/osc/`, `~/.config/tea/config.yml` or `~/.netrc`.
The client sends an `Authorization: Bearer <token>` header; osc reads the oscrc itself.
`--apikey <key>`, `--apisecret $SECRET` and `https://<user>:<token>@host/` are slots.
`bugwarden --api-key-file ~/.config/mcp-bugzilla/api-key` reads the key itself.
`gh auth status` says whether gh is logged in.

```
# Wrong forms -- a comment in a fence, not a heading
cat ~/.netrc <!-- flag -->
```

## Wrong forms

- `cat ~/.oscrc` → never.

### A subsection of the wrong forms

- `echo "$(gh auth token)"` → never.

## After the wrong forms

Then `head -3 ~/.netrc`. <!-- flag -->
