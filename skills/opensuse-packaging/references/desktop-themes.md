# Desktop themes, icon themes and branding

Owner of: packaging a theme (icon, GTK, GNOME Shell, Plasma, SDDM, Plymouth, Firefox, Sway)
and its desktop-specific pieces: naming, what rpmlint's branding check judges, directory
ownership, per-desktop `Supplements`, shipped defaults, and keeping a theme `noarch`. The
generic spec rules stay in `references/specfile-guidelines.md`. Every rule below was checked
against Factory specs and build logs (2026-10).

## Branding package or plain theme

**Name a package `*-branding-<flavor>` only when it takes over the distribution's single
default slot for a base package.** Such a package Provides and Conflicts `<base>-branding`
and is pulled in by `Supplements: (<base> and branding-openSUSE)`; the base package Requires
`<base>-branding` (gtk3-branding-openSUSE: `Provides: gtk3-branding = %{gtk3_version}`,
`Conflicts: gtk3-branding`; gdm-branding-openSUSE: `Supplements: (gdm and branding-openSUSE)`).
An optional, seasonal or third-party theme is a **plain theme** that installs beside
branding-openSUSE and conflicts with nothing.

**rpmlint's BrandingPolicyCheck judges the packages you Require, not only your own name.**
- Only a name matching `\S+-(branding|theme)-\S+` counts as a branding package, and must then
  carry the Provides/Conflicts/Supplements above (yaru's `gnome-shell-theme-yaru` gets
  `branding-supplements-missing`). `<name>-sddm-theme` or `<name>-icon-theme` does not match.
- Every package's Requires are checked: a required name matching that pattern gives
  `E: branding-requires-specific-flavor` (openSUSEway → `sway-branding-openSUSE`); an
  unversioned required name that merely *starts with* `…-branding` or `…-theme` gives
  `E: branding-requires-unversioned` — `pkgconfig(adwaita-icon-theme)` and
  `hicolor-icon-theme` both count.
- These errors carry no score (badness threshold 999), so they never fail a build. Factory's
  own themes leave them unfiltered (adwaita-xfce-icon-theme, elementary-xfce-icon-theme have
  no rpmlintrc); if you filter one, filter that exact dependency with a comment.

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
- **An inherited theme is a plain Requires** (elementary-xfce-icon-theme: `Requires:
  adwaita-icon-theme`; breeze6-icons: `Requires: kf6-breeze-icons >= %{kf6_version}`).
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
| `/usr/share/color-schemes` | breeze6 |
| `/usr/share/plymouth/themes` | plymouth |
| `/usr/share/sddm/themes`, `/usr/lib/sddm/sddm.conf.d` | sddm (plasma6-sddm-theme-openSUSE co-owns them) |
| `/usr/share/backgrounds`, `/usr/share/gnome-background-properties` | nobody — co-own with `%dir` (wallpapers-openSUSE-extra, budgie-backgrounds) |
| `%{_libdir}/firefox/browser/extensions` | MozillaFirefox-translations-common — co-own `%dir %{_libdir}/firefox{,/browser,/browser/extensions}` rather than require it |

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
`Requires: %{name}-plugin-two-step`), `BuildArch: noarch`. A theme does not make itself the
default: plymouth's own themes switch only when the current one is `text`, and
plymouth-theme-breeze6 has no scriptlets at all. The distro default comes from
plymouth-branding-openSUSE, and only plymouth regenerates the initrd.

## Firefox add-ons

- **An unsigned add-on loads only from the app directory,
  `%{_libdir}/firefox/browser/extensions/<id>.xpi`** (Firefox is built with
  `--with-unsigned-addon-scopes=app`); the system directory under `/usr/share/mozilla`
  (`%firefox_extdir`) accepts only signed ones. The path is arch-specific, so the package is.
- **`Requires: MozillaFirefox%{?_isa}`, and `%{?_isa}` in its Supplements too**: a plain
  `MozillaFirefox` lets an i586 build install next to a 64-bit Firefox, which never reads
  `/usr/lib/firefox`.
- firefox-esr has its own progdir (`%{_libdir}/firefox-esr`, as in
  MozillaFirefox-branding-openSUSE's multibuild); `E: no-binary` on 32-bit builds is harmless
  (rpmlint exempts only lib64 paths).

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
  are noise. The flavor reruns the whole build, `%check` included.

## Publishing and testing from the repository

- `osc results` **`finished`** means the build is done and waits for that architecture's
  scheduler, which can lag hours; other arches publish meanwhile. It is not a failure.
- On x86_64, zypper accepts i586 packages: while x86_64 is unpublished it installs the i586
  build of an arch-specific package, and **`zypper up` never switches the arch back** — the
  tester needs `zypper in -f <pkg>.x86_64` (or `zypper dup`).
