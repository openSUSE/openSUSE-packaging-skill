# spec-cleaner: invocation, deviations, mechanical rewrites

## Checking a spec file

When the user asks "does this spec follow the guidelines?", "is this spec OK?", "lint this spec", etc., **run `spec-cleaner` first** — it's the canonical openSUSE style checker and applies the same rules the OBS spec-cleaner bot will. Do **not** reach for `rpmlint` for a spec-file lint; rpmlint is the post-build package checker and surfaces a different (and much smaller) set of issues at this stage.

Every behaviour below was checked against **spec-cleaner 1.3.0** (2026-10-17, rpm 4.20). `scripts/gate.sh` runs this invocation itself and goes red on a non-empty diff, so it runs in OBS-ONLY mode too.

**`gate.sh` prints the spec-cleaner version and notes any other than 1.3.0, older or newer: the rewrites below may differ there.** openSUSE:Backports:SLE-16.0 ships 1.2.4+2, whose one documented false hunk is a second `License:` inserted after `Release:` when Summary and License sit inside a `%if` flavor block (a `_multibuild` spec) — never apply it, and name it with `--cleaner-deviation`. Any other hunk is a finding like any other: apply it, or check it with 1.3.0 from Factory (`osc getbinaries openSUSE:Factory spec-cleaner standard x86_64`, unpacked with `rpm2cpio … | cpio -id` and run as `python3 <root>/usr/bin/spec-cleaner` with `PYTHONPATH` at its `site-packages`).

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
  - **`--perl` can be *destructive* on specs that are not Perl packages but carry `BuildRequires: perl`**: it explodes the single `perl` dep into hundreds of `perl(...)` provider BRs (about 715 on 1.3.0); an older version was also seen to drop an adjacent unrelated `BuildRequires` line (a JS-runtime spec lost `git-core`), which 1.3.0 did not reproduce. `--perl` maps only packages in its data, each to every module it ships (`perl-Test-Deep` → 45 lines); an unknown `perl-Foo-Bar` is left alone. On non-Perl packages, if a `--perl` pass produces a large BR explosion, drop the flag for that package and record the deviation in a spec comment; the other three flags stay mandatory.
  - **`--pkgconfig` *over-expands* one `-devel` into several `pkgconfig()`, and trimming the expansion to what the package really uses is a required step of the conversion** — it maps a `-devel` to **every** `.pc` that package ships (e.g. `libevent-devel` → `pkgconfig(libevent)` + `libevent_core` + `libevent_extra` + `libevent_openssl` + `libevent_pthreads`; `libunwind-devel` → 4 variants; `libopenssl-devel` → `libcrypto`+`libssl`+`libopenssl`+`openssl`). **Trim the expanded list to the subset the source actually uses**, read off the source itself: the names in its pkg-config checks (`PKG_CHECK_MODULES`, `pkg_check_modules`, meson `dependency()`), the headers it includes and the libraries it links. In the common case that subset is the one principal `pkgconfig()` per dependency (e.g. just `pkgconfig(libevent)`, `pkgconfig(libunwind)`, `pkgconfig(libcrypto)`+`pkgconfig(libssl)`); where the source uses several of a package's `.pc` files, keep every used one. The kept deps still pull the **same `-devel`**, which provides *all* its `.pc` files, so the buildroot — and the build — are unchanged; the trim is what removes the deps the build never consumes. The trimmed form is **spec-cleaner-stable** (it only re-expands `-devel` *names*, not existing `pkgconfig()` deps, so a no-diff run confirms it). Run the conversion in this order: convert, trim to the used subset, re-run spec-cleaner to a no-diff state, then rebuild to validate (the linker pulling the expected libs is the proof). Real case: monero — trimmed ~20 expanded `pkgconfig()` back to 9 principals, built identically. **A nastier variant — version constraint copied onto an independently-versioned sub-`.pc`:** when the `-devel` carried a `>= X.Y`, spec-cleaner copies that constraint onto *every* expanded `pkgconfig()`, including sub-libraries that version on their own scheme. `libxslt-devel >= 1.1.9` → `pkgconfig(libxslt) >= 1.1.9` **+ `pkgconfig(libexslt) >= 1.1.9`**, but `libexslt.pc` is `0.8.x`, so the build dies in dep-resolution: *"nothing provides pkgconfig(libexslt) >= 1.1.9 (got 0.8.25)"*. Drop the bogus constraint on the sub-`.pc` (keep `pkgconfig(libexslt)` unversioned) — the version belongs only on the principal `.pc`. (Real case: xmlstarlet.)
    - **When the several `.pc` are *semantically distinct* (not just split variants of one lib), pick the right one by how the source uses it — don't blind-trim to "principal."** Some `-devel` ship genuinely different APIs under different `.pc` names, where keeping the wrong one is a real (if currently-harmless) mismatch. The classic is **`libbsd-devel` → `pkgconfig(libbsd)` + `pkgconfig(libbsd-overlay)`**: `libbsd` exposes its functions under a `bsd/` header prefix (`#include <bsd/string.h>`), while `libbsd-overlay` adds `-I.../libbsd` so the *unprefixed* system headers gain the BSD functions (`#include <string.h>` → `strlcpy`). Grep the source for the include style — prefixed `bsd/…` includes → keep `pkgconfig(libbsd)`; unprefixed includes relying on the overlay → keep `pkgconfig(libbsd-overlay)`. (Real case: libdispatch 6.1.1 uses `check_symbol_exists(__printflike "bsd/sys/cdefs.h")` — the `bsd/` prefix → `pkgconfig(libbsd)`, dropping the over-expanded `-overlay`.)
  - **More over-expansion footguns spec-cleaner commits — REJECT these and keep the package-name form (accepted no-diff deviations):**
    - **`--perl` explodes `autoconf` into its perl modules** (10 `perl(Autom4te::…)` lines on 1.3.0). Keep the literal `autoconf` — it is a tool dependency, not a perl one. (1.3.0 keeps `automake` and `git-core`, which older versions exploded too. Real case: xar.)
    - **`--pkgconfig` turns `python3-devel` into `pkgconfig(python3)` + `pkgconfig(python3-embed)`** on 1.3.0 (older versions wrote a stale `pkgconfig(python-3.6)`). Both resolve; keep `pkgconfig(python3)` alone unless the package embeds the interpreter, or keep `python3-devel`.
    - **A `pkgconfig(foo)` conversion is only safe if `foo.pc` exists** — `rpm -ql <pkg>-devel | grep '\.pc$'` when in doubt. (1.3.0 no longer converts `uthash-devel`, which ships no `.pc`, nor any `Provides:`/`Obsoletes:`; the rule stands for whatever its data still maps.)
    - **`--tex` can explode a *multi-file* texlive package into individual `tex(file.ext)` BuildRequires that don't all resolve.** `texlive-latex` (148 `tex()` lines on 1.3.0), `texlive-amsmath`, `texlive-fancyhdr`, etc. each bundle dozens of `.cls`/`.sty`/`.def`/`.tex` files together; spec-cleaner converts the one package-name dep into one `tex(...)` line per file it can find — and some of those names (e.g. `tex(source2e.tex)`, `tex(utf8-test.tex)`, `tex(utf8test.tex)`) are upstream TeX Live source/test artifacts that no installed package actually provides, so `osc build`'s buildinfo comes back `unresolvable: nothing provides tex(source2e.tex)` and the build never starts. `zypper se --provides "tex(name.ext)"` resolving for a handful of spot-checked names is **not** sufficient proof — the failure only shows up for the specific unlucky names, so the real gate is a green local build, not a per-name resolve check. Keep the texlive-*package-name* form for any texlive package that bundles multiple files; only accept a per-file `tex(...)` swap when that upstream package genuinely maps 1:1 to one file (e.g. `texlive-footnotehyper` → `tex(footnotehyper.sty)`, which is what it ships). (Real case: sdcc 4.6.0.)
    In each of these the spec is **not** no-diff (spec-cleaner re-suggests the expansion every run) — that's an accepted deviation; verify the *rest* of the diff is empty and move on.
  - **It strips an explicit `-p0` from `%patch -P N -p0`; on rpm 4.20 that is harmless** — `rpmspec -P` expands both forms to `patch … -p0`, rpm's default. Accept it.
  - **Beware macro-ification *inside a `sed`/`grep` pattern*, and of any literal upstream path spec-cleaner mistakes for one of ours.** spec-cleaner rewrites path-looking text anywhere it finds it, including a literal string you are *matching* in upstream content, or a literal directory name from the extracted source tree that merely happens to spell a macro's expansion — e.g. `sed -e '1s|^#!/usr/bin/env node$|…|'` becomes `#!%{_bindir}/env node`, or a relative source path that spells one, `./usr/share/x` → `.%{_datadir}/x` (1.3.0 keeps one inside a word, `cmd/foo/etc/`). 1.3.0 also rewrites `/etc` → `%{_sysconfdir}` and the systemd, tmpfiles, sysusers, udev, sysctl, nodejs, fonts, emacs and apparmor directories — see the paths table. Both expand to the same bytes today, but the line now reads as a path *we* emit rather than upstream text we're matching or upstream's own tree layout, and both silently break if the macro's expansion ever diverges from the literal (or if the sed pattern is meant to match text that predates the macro existing). Keep the literal; accepted deviation. (Real cases: typescript-go's typescript7 shebang fixup; syncthing's `cmd/strelaysrv/etc/linux-systemd/` install source; gnu_parallel's `#!/usr/bin/env perl` shebang-fixup sed pattern.)
  - **Beware bracing a *parameterized* macro — `%{macro} arg` is not the same call as `%macro arg`.** `%macro arg` expands the macro *with* `arg` as its parameter; `%{macro} arg` expands the (now zero-argument) macro first and leaves `arg` as unrelated trailing literal text. spec-cleaner sometimes wraps a bare macro invocation in braces as if it were a plain value macro (`%name` → `%{name}`, always safe) without checking whether the macro actually consumes the rest of the line as an argument. On a parameterized macro this is a real break, not a style nit: the arguments no longer reach it. 1.3.0 still braces `%gobuild ./cmd/foo`, `%gotest ./...`, `%tmpfiles_create_package foo foo.conf` and `%python_files foo`; it now leaves the systemd and service scriptlet macros alone (on its exclude list). Keep the bare `%macro arg` form for any macro that takes arguments and treat the brace-wrap as an accepted deviation. (Real case: syncthing 2.1.5, `%systemd_user_preun %{name}.service`, failed at spec-parse time on an older version.)

**Documenting one of these deviations: never write the broken syntax literally.** RPM macro-expands *everywhere*, not just executable spec sections — including `#`-comments (`warning: Macro expanded in comment`, but it still evaluates) and the free-text body of `%changelog` entries, with no warning at all there. A spec comment or `.changes` bullet that literally quotes the offending sequence (`` `%{systemd_user_preun}` rewrite breaks... ``) gets macro-expanded by RPM the same as a real invocation, reproducing the exact parse error the comment was written to explain — one line earlier than the actual bug, which makes it more confusing to diagnose, not less. Describe the deviation in prose instead ("wrapping systemd_user_preun in braces breaks argument passing" — no `%`/`%{}` around the macro name at all); if you must show the literal syntax, escape every `%` as `%%`. Check both the spec comment *and* the matching `.changes` entry — the same session can (and did) hit this twice, once in each file. (Real case: syncthing 2.1.5 — the spec-comment version was caught by a local build, the `.changes`-entry version by the adversarial reviewer.)
- `--perl` — convert deps to `perl(...)` (**always pass**; long option only, no short form).
- `-t` / `--tex` — convert deps to `tex(...)` (**always pass**).
- `-c` / `--cmake` — convert deps to `cmake(...)` (pass when the package is CMake-based and uses `cmake()`-style deps).
- `-i` — inline edit (modifies the file)
- `-d` — diff against original (default diff tool is `vimdiff`; override with `--diff-prog`)
- `-o FILE` — write the cleaned output to FILE
- `--copyright-year YYYY` — set the copyright year in the regenerated header
- `--suse-copyright` — use the official SUSE copyright header text
- `-m` / `--minimal` — documented as copyright-only, but on 1.3.0 it still rewrote 40 lines of a test spec: don't rely on it
- `-f` — overwrite an existing `-o` target (the stale-output trap above needs no `rm` then)

Operational notes:
- spec-cleaner prints **nothing on success**. Silence + empty diff = the spec is already canonical. Don't keep poking it expecting an "OK".
- Always snapshot before running `-i` (`cp foo.spec /tmp/foo.spec.before`) so you can `diff -u` afterwards and show the user what changed.
- It only rewrites *style and mechanically-fixable bugs*. It will **not** flag a wrong `License:` SPDX choice, a missing `%check` section, or language-policy violations (Python flavour macros, shlib package naming, etc.) — those require the human review per `references/specfile-guidelines.md`.
- A spec can opt out of automatic cleanup by including `#nospeccleaner` somewhere in the file.
- `spec-cleaner -o <file>` refuses to overwrite an existing output file (errors with `ERROR: <file> already exists.`). When iterating on a cleanup, either `rm -f /tmp/cleaned.spec &&` before each run or use a fresh path each time.
- **(Fixed in 1.3.0, which moves such a line to the end of the dependency block like the `%if` form.) A conditional dependency written as a standalone macro line — `%{?with_foo:BuildRequires:  foo}` — was *hoisted to the top of the preamble* by older versions, above the `%bcond`/`%define` that defines `with_foo`.** spec-cleaner treats any line starting with a bare `%{...}` as a preamble define and moves it up with the other defines, which silently **breaks the conditional** (the macro is now evaluated before it's defined). This is a case where blindly applying spec-cleaner's output is wrong. The fix that is both correct *and* spec-cleaner-stable: rewrite the one-liner as a real conditional block —
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
| `/usr/lib64` | `%{_libdir}` |
| `/usr/lib` | `%{_prefix}/lib` (1.3.0; not `%{_libdir}`) |
| `/usr/libexec` | `%{_libexecdir}` |
| `/usr/include` | `%{_includedir}` |
| `/usr/share` | `%{_datadir}` |
| `/usr/share/man` | `%{_mandir}` |
| `/usr/share/info` | `%{_infodir}` |
| `/usr/share/doc/packages` | `%{_docdir}` |
| `/var`, `/var/adm/…` | `%{_localstatedir}`, `%{_localstatedir}/adm/…` |
| `/etc/init.d` | `%{_initddir}` |
| `/usr` (alone), `%_exec_prefix` | `%{_prefix}` |
| `/etc` | `%{_sysconfdir}` |
| the systemd unit, tmpfiles, sysusers, udev rules and sysctl directories | `%{_unitdir}`, `%{_tmpfilesdir}`, `%{_sysusersdir}`, `%{_udevrulesdir}`, `%{_sysctldir}` (1.3.0) |
| the nodejs, fonts, emacs site-lisp and apparmor profile directories | `%{nodejs_sitelib}`, `%{_fontsdir}`, `%{_emacs_sitelispdir}`, `%{apparmor_profilesdir}` (1.3.0): **no BuildRequires is added, and each is undefined until the package that defines it is in the build root** — add that BuildRequires, or the path stays a literal `%{…}` |

A spec that `%define`s one of these macros itself keeps its paths.

**Licenses**
- SPDX legacy → modern: `GPL-2.0` → `GPL-2.0-only`, `GPL-2.0+` → `GPL-2.0-or-later`, `LGPL-2.1+` → `LGPL-2.1-or-later`, etc. The `+` suffix is dropped in favour of `-or-later`; bare names get the `-only` suffix.
- Fedora-style prose: `GPLv2 or later` → `GPL-2.0-or-later`.
- Operator case normalised: lowercase `and` / `or` / `with` → uppercase `AND` / `OR` / `WITH`.
- Separators normalised: `;` between licenses → `AND`; trailing `;` stripped.
- A subpackage gets the main package's `License:` written out only when the spec carries more than one distinct license; a subpackage `License:` identical to the main one is removed.
- Files matching `COPYING*`, `LICEN[SC]E*`, `*license*` move automatically from `%doc` to `%license`.

**Sources / Patches**
- All `Source*` / `Patch*` tags sorted by number, aligned to column 16.
- A bare `Source:` stays unnumbered (1.3.0); a bare `Patch:` becomes `Patch0:` only when a bare `%patch` refers to it.
- `NoSource:` lines grouped after all `Source` tags.
- `%patchN -p1` → `%patch -P N -p1` (the bare-numeric form is deprecated in modern rpm).
- `%setup -q -n %{name}-%{version}` → `%setup -q` (default `-n` value elided); non-default `-n` (e.g. `-n %{name}-%{version}-src`) preserved.
- `http://` → `https://` after a **live probe** of each URL and Source (up to 5 s each, 1.3.0): spec-cleaner makes these network calls itself, and offline it changes nothing.
- `http://pypi.python.org/packages/source/…` → `https://files.pythonhosted.org/packages/source/…`.
  - **Verify a hashed pythonhosted `Source` after running it.** 1.3.0 keeps the canonical lowercase `xx/yy/<60-hex>` path but still mangles a non-canonical one; older versions mangled them all. If a spec pins the per-file hashed path `…/packages/b5/e7/<64-hex>/inspektor-%{version}.tar.gz`, spec-cleaner rewrites it to a **malformed** `…/packages/b5/i/inspektor/inspektor-%{version}.tar.gz` (it keeps the first 2-char hash segment but drops the rest), which 404s. The fix is to use the canonical **redirect** form `https://files.pythonhosted.org/packages/source/<first-letter>/<pkg>/<pkg>-%{version}.tar.gz` — it is version-templated (so it survives the *next* bump too, unlike a hash path you'd have to re-edit every release) and spec-cleaner leaves it alone. (Real case: python-inspektor 0.5.3 — spec-cleaner mangled the hash URL to `b5/i/inspektor`; switched to `source/i/inspektor`.)

**Dependencies** (`BuildRequires` / `Requires` / `Conflicts` / `Provides` / `Obsoletes` / `Supplements` / `Recommends` / `Suggests` / `Enhances`)
- Multi-package one-liners (space- or comma-separated) split into one package per line.
- Sorted alphabetically within each tag, with non-bracket deps before bracket deps (`pkgconfig(...)`, `cmake(...)`, `perl(...)`, `rubygem(...)`).
- Identical dep lines de-duplicated (with attached comment context preserved).
- When any `pkgconfig(...)` appears, hand-written ones included, an explicit `BuildRequires: pkgconfig` is injected (to ensure the `Requires: pkgconfig` runtime dep is generated).
- A trailing `# …` or `%dnl` comment on a dependency line is kept; `^` versions and `%{?bar}` values no longer crash the parser (1.3.0).
- Whitespace around operators normalised: `iii  <=     4.2.1` → `iii <= 4.2.1`.
- Invalid RPM operators corrected: `=>` → `>=`, `==` → `=`.
- Known package renames applied: `gtk2-devel` → `pkgconfig(gtk+-2.0)` (and friends), `zlib-devel` → `pkgconfig(zlib)`, `pwdutils` → `shadow` (on `Requires` only).
- Modern boolean deps: `packageand(A:B)` → `(A and B)`.
- `Requires(post): a b c` → three separate `Requires(post):` lines.
- With `-p` flag: `perl-Foo-Bar` → `perl(Foo::Bar)`.

**Preamble layout**
- Tag order normalised within a (sub)package block: `Name`, `Version`, `Release`, `Summary`, `License`, `Group`, `URL`, `Source*`, `Patch*`, `BuildRequires*`, then `Requires`, `Recommends`, `Suggests`, `Enhances`, `Supplements`, `Conflicts`, `Provides`, `Obsoletes` (1.3.0).
- A `%global` that reads the version (`%global pyver %{version}`) is moved to just after `Release:` (1.3.0).
- `Release: <number>` always rewritten to `Release: 0` (OBS sets the real release); string-form releases like `2.2donotclean` preserved.
- `ExcludeArch` / `ExclusiveArch` moved to the end of the preamble; one inside an `%if` block stays put (1.3.0).
- `Group:` values not on the [approved list](https://en.opensuse.org/openSUSE:Package_group_guidelines) get a `# FIXME: use correct group or remove it…` comment. With `--remove-groups` (the default in this skill — see Core directive), the line is stripped entirely instead.
- `%package -n foo-lang` / `%package lang` gets a `# FIXME: consider using %%lang_package macro` comment; with `%lang_package`, a `Recommends: %{name}-lang` is dropped as redundant (1.3.0).

**Files section**
- `/path` → `%{macro}/...` per the paths table above.
- Manpage `.gz` and info `.info.gz` suffixes replaced with `%{?ext_man}` / `%{?ext_info}` (compression suffix is OS-dependent; the variable handles it).

**Scriptlets**
- Single-command `%post` / `%postun` running only `/sbin/ldconfig` collapsed to one-liner `%post -p /sbin/ldconfig`.
- `%{run_ldconfig}` → `-p /sbin/ldconfig`.
- **It never writes `%ldconfig_scriptlets`** (1.3.0): a matching `%post -n X -p /sbin/ldconfig` / `%postun -n X -p /sbin/ldconfig` pair stays as it is. Convert the pair by hand to `%ldconfig_scriptlets -n X` (`%ldconfig_scriptlets` for the main package); spec-cleaner leaves that form alone. Upstream: rpm-software-management/spec-cleaner#452 asks it to do the conversion.
- Trailing whitespace stripped on scriptlet header lines.

**Python-specific** (always-on, no `-p`)
- Inside `%python_expand`: `%{python_sitelib}` / `%{python_sitearch}` / `%{python_version}` / `%{python_bin_suffix}` rewritten to the `$python_*` flavour-variable form `%{$python_sitelib}` etc., and bare `python` → `$python`. These forms expand once per flavour during build. **On 1.3.0 a multi-line `%{python_expand …}` block gets only its first line rewritten** — fix the rest by hand.
- `%python_expand PYTHONPATH=… python -m pytest …` → `%pytest …` (1.3.0).
- Bare `%oldpython-base` → `%{oldpython}-base`.
- `Source0: http://pypi.python.org/packages/source/...` → `https://files.pythonhosted.org/packages/source/...`.
- `%{python_sitelib}/*` glob in `%files` expanded to the canonical pair: `%{python_sitelib}/<modulename>` + `%{python_sitelib}/<modulename>-%{version}*-info` — the module name is taken from the spec's **file name**, so check it.

**Header / copyright** — without `--suse-copyright` (the canonical invocation) the header is left untouched and none is added, `--copyright-year` alone included. With it (1.3.0):
- the copyright lines become one `Copyright (c) YYYY SUSE LLC and contributors` line; third-party lines are kept, an old `SUSE LINUX GmbH` line is dropped;
- the "spec file for package X" name comes from the spec's file name;
- `http://bugs.opensuse.org/` → `https://bugs.opensuse.org/`;
- OBS service hint lines (`# norootforbuild`, `# icecream`, …) are sorted but **not** de-duplicated.

`--no-header` no longer exists (exit 2).
