# Desktop themes, icon themes, branding and `.desktop` files

Owner of: packaging a theme (icon, GTK, GNOME Shell, Plasma, SDDM, Plymouth, Firefox, Sway)
and its desktop-specific pieces: naming, what the build log's rpmlint branding check judges
(and where rpmcrab differs), directory ownership, per-desktop `Supplements`, shipped
defaults, and keeping a theme `noarch`; and a GUI app's `.desktop` file ("Desktop files /
GUI apps"). The generic spec rules stay in `references/specfile-guidelines.md`. Every theme
rule below was checked against Factory specs and build logs (2026-10).

## Branding package or plain theme

**Name a package `*-branding-<flavor>` only when it takes over the distribution's single
default slot for a base package.** Such a package Provides (versioned, `=`) and Conflicts
`<base>-branding` and is pulled in by `Supplements: (<base> and branding-<flavor>)`; the base
package Requires or Recommends `<base>-branding` (gtk3-branding-openSUSE: `Provides:
gtk3-branding = %{gtk3_version}`, `Conflicts: gtk3-branding`; gtk3 has `Recommends:
%{name}-branding`, gdm `Requires: %{name}-branding = %{version}`). An optional, seasonal or
third-party theme is a **plain theme** that installs beside branding-openSUSE and conflicts
with nothing.

**rpmlint's BrandingPolicyCheck sorts packages by their own name first** (rpmlint 2.10,
`rpmlint/checks/BrandingPolicyCheck.py`):
- **A name matching `\S+-(branding|theme)-\S+` is checked as a branding package** of type
  `branding` or `theme`: it must Provide (`=`) and Conflict `<base>-<type>`, carry
  `Supplements: (<base> and <type>-<flavor>)`, and have no Recommends/Suggests/Enhances
  (those are warnings); its Requires are not checked. A plain theme named
  `<base>-theme-<flavor>` therefore gets `E: branding-provides-missing`,
  `branding-conflicts-missing <base>-theme` and
  `branding-supplements-missing (<base> and theme-<flavor>)` — lxqt-theme-openSUSE-default,
  gnome-shell-theme-yaru and plymouth-theme-breeze6 carry them and leave them. **Never add that
  Conflicts or Supplements to a plain theme** (it would conflict with the real branding
  package and install itself wherever the base is), and never rename a package just to dodge
  the check. A name ending in `-theme` (`<name>-sddm-theme`, `<name>-icon-theme`) does not
  match.
- **Every other package has its Requires checked**: a required name matching that pattern
  gives `E: branding-requires-specific-flavor` (openSUSEway → `sway-branding-openSUSE`); an
  unversioned required name that *contains* `-branding` or `-theme` after its first
  character gives `E: branding-requires-unversioned` — `lxqt-themes`, `hicolor-icon-theme`
  and `pkgconfig(adwaita-icon-theme)` all count.
- Each of these errors adds 1 to the badness (yaru-theme: 20 errors, 20 badness); a build
  fails only past the threshold of 999. Factory's own themes leave them unfiltered
  (adwaita-xfce-icon-theme and elementary-xfce-icon-theme have no rpmlintrc); if you filter
  one, filter that exact dependency with a comment.
- **rpmcrab, run over the built RPMs, diverges.** It charges the provides, conflicts and
  supplements trio only to `-branding-` names, so a plain `<base>-theme-<flavor>` gets none
  of the three (rpmcrab#954). It reports `branding-requires-unversioned` as `W:` and
  only for a generic `<base>-branding` or `<base>-theme` name, so `lxqt-themes`,
  `hicolor-icon-theme` and `pkgconfig(adwaita-icon-theme)` pass (rpmcrab#857, #953).

**Require an icon theme by its package name, never by `pkgconfig()`**: `Requires:
adwaita-icon-theme`, as every Factory theme does — the `.pc` file is a build-time artifact.

## Icon themes

- **`%icon_theme_cache_create_ghost <Theme>` in `%install` and `%ghost
  %{_datadir}/icons/<Theme>/icon-theme.cache` in `%files` — always as a pair**
  (adwaita-icon-theme, kf6-breeze-icons). `%ghost` alone gives `W: zero-perms-ghost` (yaru);
  `create_ghost` alone ships a real empty file, `E: zero-length` (mint-y).
- The cache is rebuilt by gtk3's file trigger on `%{_datadir}/icons` (`%filetriggerin tools`);
  `%icon_theme_cache_post`/`_postun` are now no-ops. adwaita adds `Requires(post): (gtk3-tools
  if libgtk-3-0)`. Expect and leave `warning: File listed twice: …/icon-theme.cache` (the
  directory and the `%ghost` both list it) and `W: ghost-files-without-postin` — Factory's
  icon themes carry both.
- **An inherited theme is a plain Requires** (mint-y-icon-theme: `Requires:
  adwaita-icon-theme`, `gnome-icon-theme`, `hicolor-icon-theme`).
- `%fdupes %{buildroot}%{_datadir}` (hardlinks) when the tree spans subpackages; `%fdupes -s`
  only when everything lands in one package.

## Links into another package

**A symlink whose target another package ships needs that package as BuildRequires *and*
Requires.** `brp-25-symlink` fails the build when the target exists neither in the build
root nor in the installed system ("link target doesn't exist … Add the package providing
the target to BuildRequires and Requires"); the Requires keeps it resolving after install
(lxqt-theme-openSUSE-default: `BuildRequires: lxqt-themes`, `Requires: lxqt-themes`).
- The check runs at build time against *that* distribution's package: a link list made from
  one version can miss targets in an older one (Leap 16.0's Breeze lacked 1 of 438 icons a
  Tumbleweed-built list linked to), and a later update of the target can leave links
  dangling. Say which version the list was made from.
- The alternative is to copy the target at build time (plasma6-openSUSE rsyncs Breeze into
  breeze-openSUSE): no runtime coupling, but the copy goes stale until rebuilt.

## Directory owners

Own a directory with `%dir` or Require the package that owns it — `osc build` reports an
unowned one. Owners in Factory:

| directory | owned by |
|---|---|
| `/usr/share/icons`, `/usr/share/themes`, `/usr/share/sounds` | filesystem |
| `/usr/share/plasma`, `/usr/share/wallpapers` | kf6-filesystem |
| `/usr/share/plasma/desktoptheme` | libplasma6-desktoptheme (kalpa-themes co-owns it) |
| `/usr/share/plasma/look-and-feel` | plasma6-workspace |
| `/usr/share/color-schemes` | breeze6-style |
| `/usr/share/plymouth/themes` | plymouth |
| `/usr/share/sddm/themes`, `/usr/lib/sddm/sddm.conf.d` | sddm (plasma6-sddm-theme-openSUSE co-owns them) |
| `/usr/share/backgrounds`, `/usr/share/gnome-background-properties` | gnome-backgrounds (GNOME only) — co-own with `%dir` rather than require it, as wallpapers-openSUSE-extra (`gnome-background-properties`, `wallpapers`) and budgie-backgrounds (`backgrounds`) do |
| `%{_libdir}/firefox`, `…/firefox/browser` | MozillaFirefox |
| `%{_libdir}/firefox/browser/extensions` | MozillaFirefox-translations-common and -other — with `Requires: MozillaFirefox%{?_isa}`, co-own only this one with `%dir` |

## Per-desktop pieces — boolean Supplements

**Split a theme per desktop and let each piece pull itself in with `Supplements: (<meta> and
<marker>)`**, so installing the metapackage brings only what the installed desktops use
(yaru: `Supplements: (metatheme-yaru-common and gnome-shell)`, `… and xfwm4)`; breeze6-gtk:
`(breeze6-style and gtk3)`; gnome-browser-connector: `(gnome-shell and MozillaFirefox)`).
- Markers in use: `plasma6-workspace`, `gnome-shell`, `xfwm4`/`xfce4-session`, `sway`,
  `sddm`, `gdm`, `plymouth`, `MozillaFirefox`, `gtk3`/`gtk4`. The older `packageand(a:b)` form
  still appears in branding packages.
- **Pick a marker that only exists where the piece belongs.** A piece that Requires a
  Plasma-only package must not supplement `sddm`, or an LXQt system with SDDM gets Plasma
  dragged in: supplement the package it actually needs (`plasma6-sddm-theme-openSUSE`).
- `Supplements` and `Recommends` are weak: with `solver.onlyRequires = true` (minimal images)
  only the metapackage's Requires come along — say so in the README, don't turn the pieces
  into Requires.

## Defaults — SDDM drop-ins and GSettings overrides

- **SDDM** reads `/usr/lib/sddm/sddm.conf.d/NN-*.conf` in order: `00-general.conf` (sddm),
  `10-plasma.conf` (sddm-qt6-branding-openSUSE), `20-breeze-openSUSE.conf`
  (plasma6-sddm-theme-openSUSE, "This overrides 10-plasma.conf"). A theme's drop-in takes a
  number above the one it overrides; `/etc/sddm.conf.d` stays the admin's.
- **GSettings** overrides are `/usr/share/glib-2.0/schemas/NN_*.gschema.override`:
  `20_openSUSE-branding` (gio-branding-openSUSE), `30_<product>` (Aeon, MicroOS).
- **No `%post`**: glib2-tools' file trigger on the schemas directory recompiles them, and
  the `%glib2_gsettings_schema_*` macros are no-ops. **Require the packages that own the
  schemas you override** (glib2.spec's `#BRAND` note); a key of an absent schema only prints
  "No such schema" when the trigger runs.
- **Factory's plain themes ship no auto-installed defaults** (yaru deletes its own
  `99_Yaru` override); defaults live in branding packages or the openSUSE SDDM theme. Before
  making a plain theme's defaults install themselves (a `Supplements` on them), ask the user.

## Plymouth themes

`Requires: plymouth-plugin-<plugin>` for the plugin the `.plymouth` file names (theme-spinner:
`Requires: %{name}-plugin-two-step`), `BuildArch: noarch`. **Prefer no scriptlets**
(plymouth-theme-breeze6): choosing the theme and rebuilding the initrd stay with the
administrator. Factory has the other shape too — plymouth's theme-spinfinity and
theme-fade-in, and plymouth-theme-opensuse-beat, make themselves the default; if a theme
must, copy that exact shape: `%post` on first install only (`$1 -eq 1`) and only when the
current theme is `text`, `plymouth-set-default-theme -R <theme>` (which rebuilds the initrd)
but without `-R` inside `/.buildenv`, and `%postun` on erase (`$1 -eq 0`) running
`plymouth-set-default-theme -R --reset` if it is still the current theme. The distro default
comes from plymouth-branding-openSUSE.

## Firefox add-ons

- **An unsigned add-on loads only from the app directory,
  `%{_libdir}/firefox/browser/extensions/<id>.xpi`** (Firefox is built with
  `--with-unsigned-addon-scopes=app`). The system directory `%firefox_extdir`
  (`%{_libdir}/mozilla/extensions/<appid>`, or `/usr/share/mozilla/…` in a noarch build)
  accepts only signed ones. The path is arch-specific, so the package is.
- **`Requires: MozillaFirefox%{?_isa}`, and `%{?_isa}` in its Supplements too.** On x86_64
  zypper also accepts i586 packages: while the x86_64 build is not yet published it installs
  the i586 one, which puts the add-on in `/usr/lib/firefox`, never read by the 64-bit Firefox,
  and **`zypper up` never switches the arch back** (`zypper in -f <pkg>.x86_64` does). The
  `%{?_isa}` makes the wrong-arch build uninstallable.
- firefox-esr has its own progdir (`%{_libdir}/firefox-esr`, as in
  MozillaFirefox-branding-openSUSE's multibuild); `E: no-binary` on 32-bit builds is harmless
  (rpmlint exempts only lib64 paths). rpmcrab exempts each arch's libdir and reports
  `no-binary` as `W:` (rpmcrab#444).

## One arch-specific piece in a noarch theme

An arch-specific subpackage makes the whole spec arch-specific, empty metapackage included.
Two Factory-accepted shapes:
- **Arch spec, `BuildArch: noarch` on every other subpackage** (breeze6, plymouth, sddm) — the
  usual one; the main package stays arch.
- **A `_multibuild` flavor** builds the arch piece alone and keeps everything else, the
  metapackage included, noarch:
  ```
  %global flavor @BUILD_FLAVOR@%{nil}
  %if "%{flavor}" == "firefox"
  %define psuffix -firefox-theme
  %endif
  Name:           mytheme%{?psuffix}
  ```
  with `BuildArch: noarch` in the default flavor's branch and every other `%package`,
  `%description` and `%files` inside it. Expect `E: invalid-spec-name` on the flavor's src
  rpm and `W: libdir-macro-in-noarch-package` (rpmlint's spec check ignores `%if`); both
  are noise. rpmcrab does not report the second here (rpmcrab#1171). The flavor
  reruns the whole build, `%check` included.

## Desktop files / GUI apps

- GUI apps need a `.desktop` file following https://standards.freedesktop.org/desktop-entry-spec/. `Icon=` must be a basename (no extension).
- **A package that installs its icon to `%{_datadir}/pixmaps` (not into a `…/icons/hicolor/…` theme dir) does *not* need `Requires: hicolor-icon-theme` (nor the BuildRequires)** — pixmaps is a flat fallback dir owned by `filesystem`, unrelated to the hicolor theme. An unversioned `Requires: hicolor-icon-theme` there trips the build log's rpmlint `E: branding-requires-unversioned hicolor-icon-theme`; dropping the dependency is both correct and clears the error (rpmcrab checks only generic `<base>-branding`/`<base>-theme` names and skips this one). Only depend on `hicolor-icon-theme` when you actually install into its theme directories. (Real case: lshw-gui shipped its icon in `%{_datadir}/pixmaps` yet required `hicolor-icon-theme` — dropped.)
- **HARD RULE: `%suse_update_desktop_file` is deprecated and must always be removed** (rpmcrab flags `suse-update-desktop-file-deprecated`). Never keep it, in either form:
  - The **`-i` (in-place) form** edits an existing upstream `.desktop` — replace it by declaring that file as a `Source` and installing it directly (`install -Dm 0644 %{SOURCE1} %{buildroot}%{_datadir}/applications/<name>.desktop`).
  - The **`-c` (create) form** generates a `.desktop` from macro arguments — replace it by **shipping a hand-written `.desktop` as a `Source`** with the same fields (`[Desktop Entry]` / `Type` / `Name` / `GenericName` / `Exec` / `Icon` / `Categories=…;`) and installing it the same way. To recover the exact fields the macro produced, read the generated file from a prior build's `SOURCES/<name>.desktop` (or the BUILDROOT copy).
  - In both cases **drop `BuildRequires: update-desktop-files`** (it only provided that build-time macro — see the `Requires(post)` rule below), and don't add runtime desktop-database scriptlets (file triggers handle the cache).
  - If the spec is an altcoin-style template that seds `%{base}`→`%{name}` across its sources, write the shipped `.desktop` with the *base* tokens (e.g. `bitcoin`/`Bitcoin`) so the existing sed templating keeps working, and slot it into the reserved `Source` number the sed block already references. (Real case: bitcoin's `%suse_update_desktop_file -c` replaced by a shipped `bitcoin-qt.desktop` as `Source2`, which the spec's `%if !is_base` sed block already expected.)
- **If the old macro was supplying SUSE translations of `Name`/`GenericName`/`Comment`, migrate to `translate-suse-desktop` instead of a plain static install** (jsc#PED-15206 — the sanctioned successor for downstream-authored `.desktop` files; a bare `install` of a static file silently drops those translations). Mechanics: rename the shipped source to `<name>.desktop.in` and underscore-prefix the translatable keys (`_Name=`, `_GenericName=`, `_Comment=`); swap `BuildRequires: update-desktop-files` → `BuildRequires: translate-suse-desktop`; put the `.in` in the build cwd (e.g. `cp %{SOURCE9} .` in `%prep` — the macro expects `<name>.desktop.in` relative to where it runs); call `%translate_suse_desktop <name>.desktop` at the end of `%build` (it intltool-merges the po catalogs from `/usr/share/translate-suse-desktop` into the final `<name>.desktop`, and also writes the extracted `.pot` into `OTHER/translate-suse-desktop.tar.gz` so new strings can be fed to github.com/openSUSE/suse-desktop-translations via l10n.opensuse.org); then install the *generated* file: `install -D -m 0644 <name>.desktop %{buildroot}%{_datadir}/applications/<name>.desktop`. Not needed for upstream-shipped `.desktop` files carrying their own translations — only for SUSE-specific ones. (Real case: git's `git-gui.desktop` → `git-gui.desktop.in`, SR 1368893.)
- **HARD RULE: `update-desktop-files` is a *build-time* macro provider — never put it in `Requires(post)`/`Requires(postun)`.** It ships the build-time `%suse_update_desktop_file` macro; it is not a runtime dependency, so `Requires(post): update-desktop-files` / `Requires(postun): update-desktop-files` are simply wrong. The runtime cache-update scriptlet macros come from *different* packages: `%desktop_database_post`/`%desktop_database_postun` (run `update-desktop-database`) are from **`desktop-file-utils`**; `%icon_theme_cache_post`/`%icon_theme_cache_postun` are from **`hicolor-icon-theme`**. So if a scriptlet is genuinely needed, the `Requires(post)`/`Requires(postun)` must name *that* provider, never `update-desktop-files`.
- **Prefer dropping the desktop/mime/icon-cache `%post`/`%postun` scriptlets entirely — modern openSUSE handles them via file triggers.** `desktop-file-utils`, `shared-mime-info` and `gtk3-tools` ship the **file triggers** (`%filetriggerin -- %{_datadir}/applications`, `… %{_datadir}/mime`, gtk3's `%filetriggerin tools -- %{_datadir}/icons`) that rebuild the desktop database, MIME cache and icon cache whenever files land there. So the old manual `%post qtX`/`%postun qtX` calling `%desktop_database_post`/`%icon_theme_cache_post` (plus their `Requires(post)`/`Requires(postun)`) are redundant and should be removed. (Doubly so when the `.desktop` has no `MimeType=` — `update-desktop-database` then does nothing useful anyway.) Real case: bitcoin's `qt` subpackage carried `Requires(post)/Requires(postun): update-desktop-files` + `%post/%postun` running `%desktop_database_post` — all dropped in favour of the file triggers.
- **`%suse_update_desktop_file -i <name>` hides an orphaned source.** The `-i` form reads `<name>.desktop` from the rpm **SOURCES dir** — where osc copies *every* file in the package dir — so the build succeeds even when the `.desktop` is **not** declared as a `Source:`. But that undeclared file is an *orphaned source*: `factory-auto` declines with `Attention, "<name>.desktop" is not mentioned in spec files as source or patch`. Fix by declaring it (`Source1:  <name>.desktop`); migrating to the explicit-install form above does that anyway. (Real case: `vorta` — `vorta.desktop` was used only via `%suse_update_desktop_file -i vorta`, undeclared, and the SR was declined for the orphan; declaring it as `Source1` + explicit install fixed both the orphan and the deprecation.) This is the same orphaned-source trap as the patch case in `references/patches.md` "Patches" — any package file the build consumes must be a declared `Source`/`Patch`.
