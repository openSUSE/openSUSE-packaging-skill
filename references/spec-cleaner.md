# spec-cleaner: invocation, deviations, mechanical rewrites

## Checking a spec file

When the user asks "does this spec follow the guidelines?", "is this spec OK?", "lint this spec", etc., **run `spec-cleaner` first** — it's the canonical openSUSE style checker and applies the same rules the OBS spec-cleaner bot will. Do **not** reach for `rpmlint` for a spec-file lint; rpmlint is the post-build package checker and surfaces a different (and much smaller) set of issues at this stage.

**Canonical invocation — always pass `--remove-groups --pkgconfig --perl --tex`:**

```
# Show what spec-cleaner would change (preferred — read-only).
# NOTE the mktemp: never reuse a fixed -o path (see the stale-output trap below).
OUT=$(mktemp --suffix=.spec) && rm -f "$OUT" && \
spec-cleaner --remove-groups --pkgconfig --perl --tex -o "$OUT" path/to/foo.spec && diff -u path/to/foo.spec "$OUT"

# Or side-by-side via the user's diff tool:
spec-cleaner --remove-groups --pkgconfig --perl --tex -d --diff-prog diff path/to/foo.spec

# To apply the cleanup in place (destructive — confirm with the user):
spec-cleaner --remove-groups --pkgconfig --perl --tex -i path/to/foo.spec
```

**Always pass `--remove-groups --pkgconfig --perl --tex` on every run** (project policy in this skill):
- `--remove-groups` strips obsolete `Group:` tags.
- `--pkgconfig` / `--perl` / `--tex` convert `BuildRequires`/`Requires` to their `pkgconfig(foo)` / `perl(Foo::Bar)` / `tex(foo)` provider forms instead of `foo-devel` / `perl-Foo-Bar` / texlive package names — the preferred modern style (matches what the source comes from and lets the resolver pick the right provider).

**TRAP — `-o` refuses to overwrite, and you then diff against a stale file.** If the `-o` target already exists, spec-cleaner writes *nothing*, prints `ERROR: <path> already exists.` and exits non-zero. Chained with `&&` that stops the line; but chained with `;` — or with the spec-cleaner call piped into `head`/`tail`, which swallows its exit status — the `diff` still runs and compares your spec against **whatever package was cleaned into that path last time**. The result is a huge, confident, entirely fictitious diff. (Real case: `typescript-go` diffed against a leftover `ngtcp2` `/tmp/cleaned.spec`, "renaming" the package and rewriting every section.) Always `mktemp`/`rm -f` the target first, and never pipe the spec-cleaner call itself.

The only legitimate deviations from spec-cleaner's output are the documented semantic-correctness cases below — and even then prefer a form that is *also* no-diff stable where one exists (e.g. the `%if %{with foo}` block, the trimmed principal `pkgconfig()`).

Useful flags:
- `--remove-groups` — strip `Group:` tags (**always pass**).
- `-p` / `--pkgconfig` — convert deps to `pkgconfig(...)` (**always pass**). NOTE: `-p` is *pkgconfig*, **not** perl. **Whenever a spec has any `pkgconfig(...)` dependency, make sure `BuildRequires: pkgconfig` is also present** — pkg-config is needed at build time, and although it's usually pulled in transitively, it must be declared explicitly. spec-cleaner injects it automatically when it adds `pkgconfig(...)` deps; if you add `pkgconfig(...)` deps by hand, add `BuildRequires: pkgconfig` yourself, and verify it's there after any cleanup.
  - **`--pkgconfig` can *over-expand* one `-devel` into several `pkgconfig()`** — it maps a `-devel` to **every** `.pc` that package ships (e.g. `libevent-devel` → `pkgconfig(libevent)` + `libevent_core` + `libevent_extra` + `libevent_openssl` + `libevent_pthreads`; `libunwind-devel` → 5 variants; `libopenssl-devel` → `libcrypto`+`libssl`+`libopenssl`+`openssl`). That's noisy. It's safe to **trim to the one principal `pkgconfig()`** per dependency (e.g. just `pkgconfig(libevent)`, `pkgconfig(libunwind)`, `pkgconfig(libcrypto)`+`pkgconfig(libssl)`): the kept dep still pulls the **same `-devel`**, which provides *all* its `.pc` files, so the buildroot — and the build — are unchanged. The trimmed form is **spec-cleaner-stable** (it only re-expands `-devel` *names*, not existing `pkgconfig()` deps, so a no-diff run confirms it). Validate with a rebuild after trimming (the linker pulling the expected libs is the proof). Real case: monero — trimmed ~20 expanded `pkgconfig()` back to 9 principals, built identically. **A nastier variant — version constraint copied onto an independently-versioned sub-`.pc`:** when the `-devel` carried a `>= X.Y`, spec-cleaner copies that constraint onto *every* expanded `pkgconfig()`, including sub-libraries that version on their own scheme. `libxslt-devel >= 1.1.9` → `pkgconfig(libxslt) >= 1.1.9` **+ `pkgconfig(libexslt) >= 1.1.9`**, but `libexslt.pc` is `0.8.x`, so the build dies in dep-resolution: *"nothing provides pkgconfig(libexslt) >= 1.1.9 (got 0.8.25)"*. Drop the bogus constraint on the sub-`.pc` (keep `pkgconfig(libexslt)` unversioned) — the version belongs only on the principal `.pc`. (Real case: xmlstarlet.)
    - **When the several `.pc` are *semantically distinct* (not just split variants of one lib), pick the right one by how the source uses it — don't blind-trim to "principal."** Some `-devel` ship genuinely different APIs under different `.pc` names, where keeping the wrong one is a real (if currently-harmless) mismatch. The classic is **`libbsd-devel` → `pkgconfig(libbsd)` + `pkgconfig(libbsd-overlay)`**: `libbsd` exposes its functions under a `bsd/` header prefix (`#include <bsd/string.h>`), while `libbsd-overlay` adds `-I.../libbsd` so the *unprefixed* system headers gain the BSD functions (`#include <string.h>` → `strlcpy`). Grep the source for the include style — prefixed `bsd/…` includes → keep `pkgconfig(libbsd)`; unprefixed includes relying on the overlay → keep `pkgconfig(libbsd-overlay)`. (Real case: libdispatch 6.1.1 uses `check_symbol_exists(__printflike "bsd/sys/cdefs.h")` — the `bsd/` prefix → `pkgconfig(libbsd)`, dropping the over-expanded `-overlay`.)
  - **More over-expansion footguns spec-cleaner commits — REJECT these and keep the package-name form (accepted no-diff deviations):**
    - **`--perl` explodes any package that *provides* perl modules into the full list of those modules** — `autoconf`/`automake` → dozens of `perl(Autom4te::…)`/`perl(Automake::…)`, and `git-core` → ~20 `perl(Git)`/`perl(Git::SVN::…)` lines. Keep the literal package name (`autoconf`, `automake`, `git-core`) — it's the canonical dependency; the giant perl-module list is wrong (and `git-core` for a Go package like `gh` is plainly a tool dep, not a perl one). (Real cases: xar (autoconf/automake), gh (git-core).)
    - **`--pkgconfig` rewrites `python3-devel` into hardcoded versioned `pkgconfig(python-3.6)` + `pkgconfig(python-3.6m)`** (stale numbers baked from spec-cleaner's data — non-portable; current Python is 3.11+). Keep `python3-devel`. (Real case: molequeue.)
    - **`--pkgconfig` mis-converts a package-name `Provides:`/`Obsoletes:` that merely *looks* like a lib** — e.g. a legacy compat `Provides: libmopac7-1-devel` → `pkgconfig(libmopac7)`. That changes the semantics (a package-name provide is not a pkgconfig provider). Keep the original `Provides:` string. (Real case: openmopac.)
    - **`--pkgconfig` rewrites `uthash-devel` → `pkgconfig(uthash)`, which does not resolve** — openSUSE's `uthash-devel` ships no `uthash.pc`, so the converted dep is unresolvable (`nothing provides pkgconfig(uthash)`) and the build dies at dep-resolution. Keep `uthash-devel` and leave a one-line comment so the next person doesn't "fix" it back. (Real case: falco-libs.) General rule: a `pkgconfig(foo)` conversion is only safe if `foo.pc` actually exists — when in doubt, `rpm -ql <pkg>-devel | grep '\.pc$'` before trusting the rewrite.
    In all four the spec is **not** no-diff (spec-cleaner re-suggests the expansion every run) — that's an accepted deviation; verify the *rest* of the diff is empty and move on.
  - **It also strips an explicit `-p0` from `%patch -P N -p0` — check the patch's own headers before accepting that.** The strip level is only redundant when the patch was generated with the usual `a/`…`b/` prefixes. A patch whose headers name a **real leading directory that must survive** (`--- package/lib/getExePath.js`, no `a/` prefix) needs `-p0`, and dropping it makes `%prep` look for a path that doesn't exist. Decide from the patch, not from rpm's default: `head -3 the.patch` — if the `---`/`+++` lines carry a genuine directory component rather than `a/`/`b/`, keep `-p0` and treat the diff line as an accepted semantic deviation. (Real case: typescript-go's `getExePath-use-system-tsgo.patch`.)
  - **Beware macro-ification *inside a `sed`/`grep` pattern*.** spec-cleaner rewrites path-looking text anywhere it finds it, including a literal string you are *matching* in upstream content — e.g. `sed -e '1s|^#!/usr/bin/env node$|…|'` becomes `#!%{_bindir}/env node`. It expands to the same bytes today, but the line now reads as a path *we* emit rather than upstream text we're matching, and it silently breaks if `%{_bindir}` is ever not `/usr/bin`. Keep the literal; accepted deviation. (Real case: typescript-go's typescript7 shebang fixup.)
- `--perl` — convert deps to `perl(...)` (**always pass**; long option only, no short form).
- `-t` / `--tex` — convert deps to `tex(...)` (**always pass**).
- `-c` / `--cmake` — convert deps to `cmake(...)` (pass when the package is CMake-based and uses `cmake()`-style deps).
- `-i` — inline edit (modifies the file)
- `-d` — diff against original (default diff tool is `vimdiff`; override with `--diff-prog`)
- `-o FILE` — write the cleaned output to FILE
- `--copyright-year YYYY` — set the copyright year in the regenerated header
- `--suse-copyright` — use the official SUSE copyright header text
- `-m` / `--minimal` — only touch the copyright; leave everything else alone

Operational notes:
- spec-cleaner prints **nothing on success**. Silence + empty diff = the spec is already canonical. Don't keep poking it expecting an "OK".
- Always snapshot before running `-i` (`cp foo.spec /tmp/foo.spec.before`) so you can `diff -u` afterwards and show the user what changed.
- It only rewrites *style and mechanically-fixable bugs*. It will **not** flag a wrong `License:` SPDX choice, a missing `%check` section, or language-policy violations (Python flavour macros, shlib package naming, etc.) — those require the human review per `references/specfile-guidelines.md`.
- A spec can opt out of automatic cleanup by including `#nospeccleaner` somewhere in the file.
- `spec-cleaner -o <file>` refuses to overwrite an existing output file (errors with `ERROR: <file> already exists.`). When iterating on a cleanup, either `rm -f /tmp/cleaned.spec &&` before each run or use a fresh path each time.
- **A conditional dependency written as a standalone macro line — `%{?with_foo:BuildRequires:  foo}` — gets *hoisted to the top of the preamble*, above the `%bcond`/`%define` that defines `with_foo`.** spec-cleaner treats any line starting with a bare `%{...}` as a preamble define and moves it up with the other defines, which silently **breaks the conditional** (the macro is now evaluated before it's defined). This is a case where blindly applying spec-cleaner's output is wrong. The fix that is both correct *and* spec-cleaner-stable: rewrite the one-liner as a real conditional block —
  ```
  %if %{with foo}
  BuildRequires:  foo
  %endif
  ```
  spec-cleaner leaves `%if`-guarded `BuildRequires` in place (it only *relocates* the block to the **end of the dependency block**, after the last `Requires`/`Provides`/`Recommends`/`Suggests` — put it there yourself to reach a no-diff state in one pass). `%{with foo}` evaluates to 0 when `with_foo` is undefined, so this form is safe whether or not the `%bcond` ran. The `%{?with_foo:...}` form inside `%build`/`%check` (not the preamble) is left alone and can stay. Real case: the whole zathura/girara stack used `%{?with_gcc15:BuildRequires:  gcc15}`; converting each to the `%if %{with gcc15}` block was the only way to get a clean spec-cleaner pass without breaking the Leap-16.0 gcc15 path.

### Reference: what spec-cleaner mechanically rewrites

This list is spec-cleaner's *mechanical scope* (what it auto-applies); the *why* and the authoring rules it can't enforce live in `references/specfile-guidelines.md`. The two overlap in subject deliberately — when a rule here also carries policy/rationale, keep the rationale in specfile-guidelines and the "spec-cleaner does this automatically" fact here, rather than restating both.

Derived from the project's own [test fixtures](https://github.com/rpm-software-management/spec-cleaner/tree/master/tests) (`tests/in/foo.spec` → `tests/out/foo.spec`). When you spot any of these in a spec, expect spec-cleaner to rewrite it — don't fix it by hand first, and don't be surprised when the diff is large.

**Layout / whitespace**
- Tag values aligned to column 16 (`Name:` then 11 spaces then value).
- Tag name canonicalised: `Url:` → `URL:`, `LICense:`/`license:` → `License:`, `Buildrequires:` → `BuildRequires:`, lowercase `source:` → `Source:`.
- Trailing whitespace stripped; consecutive blank lines collapsed to one.
- `%changelog` line appended at EOF if absent.
- Bare macros curlified: `%name` → `%{name}`, `%version` → `%{version}`, `%libname` → `%{libname}`, `%kde4_runtime_requires` (on its own line) → `%{kde4_runtime_requires}`, positional `%1` → `%{1}`. A whitelist of scriptlet macros (`%insserv_cleanup`, `%service_add_pre`, `%sysusers_requires`, …) is intentionally **not** curlified.

**Obsolete / forbidden constructs**
- `%clean` section removed entirely.
- `BuildRoot:` lines removed (including gated `%if 0%{?suse_version} < 1230 … %endif` blocks around them).
- Default `%defattr(-,root,root)` / `%defattr(-,root,root,-)` removed; non-default `%defattr(644,…)` preserved.
- `BuildPreReq:` → `BuildRequires:` (BuildPreReq deprecated).
- `pkg-config` → `pkgconfig` (package renamed; applies both to direct deps and `pkgconfig(...)` requirements).
- `egrep` → `grep -E`, `fgrep` → `grep -F`.
- Every `PreReq:` line gets a `# FIXME: use proper Requires(pre/post/preun/...)` comment above it.
- Legacy ppc64-only `%ifarch ppc64` + `Obsoletes: libcap-64bit`-style blocks removed.

**Macros**
- `%makeinstall`, `make install DESTDIR=%{buildroot}`, `make install DESTDIR=$RPM_BUILD_ROOT`, `DESTDIR=%{buildroot} make install`, and every `-jN` variant → `%make_install`.
- In `%check`: `make ... check/test` (any verbosity / `-j` flags) → `%make_build ... check/test`. Bare `V=1` removed (the macro handles verbosity).
- `$RPM_BUILD_ROOT` → `%{buildroot}` (exact-token match — `$RPM_BUILD_ROOT_REPLACEMENT` left alone).
- `%{S:N}` → `%{SOURCEN}` (canonical Source reference).
- Deprecated `%suse_update_config -f` etc. removed.
- Bare `cmake .` / `./configure` / `qmake-qt5` / `meson` get a `# FIXME: you should use the %%cmake/%%configure/%%qmake5/%%meson macro` comment above them.
- Every variation of `*.la` removal collapses to: `find %{buildroot} -type f -name "*.la" -delete -print`.

**Paths → macros** (applied throughout `%files`, `%install`, etc.)

| Bare path | Replaced with |
|---|---|
| `/usr/bin` | `%{_bindir}` |
| `/usr/sbin`, `%{_prefix}/sbin` | `%{_sbindir}` |
| `/usr/lib64`, `/usr/lib` | `%{_libdir}` |
| `/usr/libexec` | `%{_libexecdir}` |
| `/usr/include` | `%{_includedir}` |
| `/usr/share` | `%{_datadir}` |
| `/usr/share/man` | `%{_mandir}` |
| `/usr/share/info` | `%{_infodir}` |
| `/usr/share/doc/packages` | `%{_docdir}` |
| `/var`, `/var/adm/…` | `%{_localstatedir}`, `%{_localstatedir}/adm/…` |
| `/etc/init.d` | `%{_initddir}` |
| `/usr` (alone), `%_exec_prefix` | `%{_prefix}` |

**Licenses**
- SPDX legacy → modern: `GPL-2.0` → `GPL-2.0-only`, `GPL-2.0+` → `GPL-2.0-or-later`, `LGPL-2.1+` → `LGPL-2.1-or-later`, etc. The `+` suffix is dropped in favour of `-or-later`; bare names get the `-only` suffix.
- Fedora-style prose: `GPLv2 or later` → `GPL-2.0-or-later`.
- Operator case normalised: lowercase `and` / `or` / `with` → uppercase `AND` / `OR` / `WITH`.
- Separators normalised: `;` between licenses → `AND`; trailing `;` stripped.
- Subpackages missing a `License:` tag inherit the main package's license explicitly.
- Files matching `COPYING*`, `LICEN[SC]E*`, `*license*` move automatically from `%doc` to `%license`.

**Sources / Patches**
- All `Source*` / `Patch*` tags sorted by number, aligned to column 16.
- `Source:` / `Patch:` (no number) → `Source0:` / `Patch0:`.
- `NoSource:` lines grouped after all `Source` tags.
- `%patchN -p1` → `%patch -P N -p1` (the bare-numeric form is deprecated in modern rpm).
- `%setup -q -n %{name}-%{version}` → `%setup -q` (default `-n` value elided); non-default `-n` (e.g. `-n %{name}-%{version}-src`) preserved.
- `http://` → `https://` for known SSL-capable hosts (PyPI, GNU FTP, Python.org, github.com, google.com, …).
- `http://pypi.python.org/packages/source/…` → `https://files.pythonhosted.org/packages/source/…`.
  - **BUT spec-cleaner CORRUPTS a full-hash pythonhosted URL — verify the `Source` after running it.** If a spec pins the per-file hashed path `…/packages/b5/e7/<64-hex>/inspektor-%{version}.tar.gz`, spec-cleaner rewrites it to a **malformed** `…/packages/b5/i/inspektor/inspektor-%{version}.tar.gz` (it keeps the first 2-char hash segment but drops the rest), which 404s. The fix is to use the canonical **redirect** form `https://files.pythonhosted.org/packages/source/<first-letter>/<pkg>/<pkg>-%{version}.tar.gz` — it is version-templated (so it survives the *next* bump too, unlike a hash path you'd have to re-edit every release) and spec-cleaner leaves it alone. (Real case: python-inspektor 0.5.3 — spec-cleaner mangled the hash URL to `b5/i/inspektor`; switched to `source/i/inspektor`.)
- Inline known `%define`s in URLs where it improves readability (e.g. `%{modname}` → `idna`).

**Dependencies** (`BuildRequires` / `Requires` / `Conflicts` / `Provides` / `Obsoletes` / `Supplements` / `Recommends` / `Suggests` / `Enhances`)
- Multi-package one-liners (space- or comma-separated) split into one package per line.
- Sorted alphabetically within each tag, with non-bracket deps before bracket deps (`pkgconfig(...)`, `cmake(...)`, `perl(...)`, `rubygem(...)`).
- Identical dep lines de-duplicated (with attached comment context preserved).
- When any `pkgconfig(...)` appears, an explicit `BuildRequires: pkgconfig` is injected (to ensure the `Requires: pkgconfig` runtime dep is generated).
- Whitespace around operators normalised: `iii  <=     4.2.1` → `iii <= 4.2.1`.
- Invalid RPM operators corrected: `=>` → `>=`, `==` → `=`.
- Known package renames applied: `gtk2-devel` → `pkgconfig(gtk+-2.0)` (and friends), `zlib-devel` → `pkgconfig(zlib)`, `pwdutils` → `shadow`.
- Modern boolean deps: `packageand(A:B)` → `(A and B)`.
- `Requires(post): a b c` → three separate `Requires(post):` lines.
- With `-p` flag: `perl-Foo-Bar` → `perl(Foo::Bar)`.

**Preamble layout**
- Tag order normalised within a (sub)package block: `Name`, `Version`, `Release`, `Summary`, `License`, `Group`, `URL`, `Source*`, `Patch*`, `BuildRequires*`, `Requires*`, `Conflicts*`, `Provides*`, `Obsoletes*`, `Supplements`, `Enhances`, `Recommends`, `Suggests`, etc.
- `Release: <number>` always rewritten to `Release: 0` (OBS sets the real release); string-form releases like `2.2donotclean` preserved.
- `ExcludeArch` / `ExclusiveArch` lifted out of conditional blocks to a fixed top-of-preamble position.
- `Group:` values not on the [approved list](https://en.opensuse.org/openSUSE:Package_group_guidelines) get a `# FIXME: use correct group or remove it…` comment. With `--remove-groups` (the default in this skill — see Core directive), the line is stripped entirely instead.
- `%package -n foo-lang` / `%package lang` gets a `# FIXME: consider using %%lang_package macro` comment.

**Files section**
- `/path` → `%{macro}/...` per the paths table above.
- Manpage `.gz` and info `.info.gz` suffixes replaced with `%{?ext_man}` / `%{?ext_info}` (compression suffix is OS-dependent; the variable handles it).

**Scriptlets**
- Single-command `%post` / `%postun` running only `/sbin/ldconfig` collapsed to one-liner `%post -p /sbin/ldconfig`.
- `%{run_ldconfig}` → `-p /sbin/ldconfig`.
- Trailing whitespace stripped on scriptlet header lines.

**Python-specific** (always-on, no `-p`)
- Inside `%python_expand` (and `%{python_expand …}` block forms): `%{python_sitelib}` / `%{python_sitearch}` / `%{python_version}` / `%{python_bin_suffix}` rewritten to the `$python_*` flavour-variable form `%{$python_sitelib}` etc., and bare `python` → `$python`. These forms expand once per flavour during build.
- Bare `%oldpython-base` → `%{oldpython}-base`.
- `Source0: http://pypi.python.org/packages/source/...` → `https://files.pythonhosted.org/packages/source/...`.
- `%{python_sitelib}/*` glob in `%files` expanded to the canonical pair: `%{python_sitelib}/<modulename>` + `%{python_sitelib}/<modulename>-%{version}*-info`.

**Header / copyright** (with `--suse-copyright`)
- Multiple/garbled copyright lines collapsed to one canonical `Copyright (c) YYYY SUSE LLC and contributors` line plus separately-attributed third-party lines.
- `http://bugs.opensuse.org/` → `https://bugs.opensuse.org/`.
- OBS service hint lines (`# norootforbuild`, `# icecream`, `# needsbinariesforbuild`, `# needsrootforbuild`, `# needssslcertforbuild`, `# nodebuginfo`, `# rootforbuild`) alphabetised and de-duplicated.
