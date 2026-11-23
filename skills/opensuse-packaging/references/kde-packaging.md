# KDE Frameworks 6 / Qt6 applications

Owner of: the KF6 build and install macros, the `%{_kf6_*dir}` file-list macros and the
KDE:* devel-project conventions for ECM-based (Qt6 / Kirigami) packages. The generic CMake
rules stay in `references/specfile-guidelines.md`; this file is where they do not apply.

## KF6 / ECM packages (Qt6, Kirigami)

Applies to a package whose devel project is KDE:* (KDE:Extra, KDE:Applications, …) and whose
`CMakeLists.txt` has `find_package(ECM …)` and `include(KDEInstallDirs)`, building against
Qt6/KF6; a dual Qt5/Qt6 project also needs its Qt6 switch (kommit:
`-DBUILD_WITH_QT6:BOOL=TRUE`). Other devel projects accept the generic forms (easyeffects in
multimedia:apps uses `%cmake` and `%{_bindir}`): match what the package already uses there. The
`%cmake_kf6` facts below hold for any spec that uses it; which forms to write is the KDE:*
convention. A KDE:Extra review declined the generic forms (sr#1381075), and every spec sampled
there (haruna, kaidan, koi, drawy, kommit, imprint, kgeotag, klevernotes) uses the KF6 build
macros, the `%{_kf6_*dir}` paths and `kf6-extra-cmake-modules`.

| generic form | KF6 form |
|---|---|
| `%cmake` + `%cmake_build` | `%cmake_kf6` + `%kf6_build` |
| `%cmake_install` | `%kf6_install` |
| `%{_bindir}` | `%{_kf6_bindir}` |
| `%{_datadir}/applications` | `%{_kf6_applicationsdir}` |
| `%{_datadir}/knotifications6` | `%{_kf6_notificationsdir}` |
| `%{_datadir}/metainfo` | `%{_kf6_appstreamdir}` |
| `%{_datadir}/icons` | `%{_kf6_iconsdir}` |
| `%{_datadir}/qlogging-categories6` | `%{_kf6_debugdir}` |
| `%{_datadir}/doc/HTML` | `%{_kf6_htmldir}` |
| `%{_datadir}/<app>` | `%{_kf6_sharedir}/<app>` — not `%{_kf6_datadir}` (= `/usr/share/kf6`) |
| `BuildRequires: extra-cmake-modules` | `BuildRequires: kf6-extra-cmake-modules >= X.Y` (the version `find_package(ECM …)` asks for, usually `${KF_MIN_VERSION}`; take it from upstream, not from a sampled spec) |

The full set is in `macros.kf6` (`geectl remote cat openSUSE:Factory kf6-filesystem macros.kf6`).
`%{_kf6_includedir}`, `%{_kf6_localedir}` and `%{_kf6_libexecdir}` are framework paths
(`…/KF6`, `…/kf6`); an app keeps `%{_includedir}` and `%{_libexecdir}`.

- **`%cmake_kf6` is not a drop-in `%cmake`: it passes `-DBUILD_TESTING:BOOL=FALSE`**, so a
  kept `%ctest` prints `No tests were found!!!` and passes. When upstream has tests
  (`if(BUILD_TESTING)`, `autotests/`, `ecm_add_test`), configure with
  `%cmake_kf6 -DBUILD_TESTING:BOOL=ON` and run `%ctest` in `%check`, as kaidan does. Judge
  "no upstream tests" from the source tree, never from a `%ctest` run after a bare
  `%cmake_kf6`; then leave `%check` out
  (`references/specfile-guidelines.md` "%prep / %build / %install / %check").
- **No Ninja setup.** `%cmake_kf6` already generates for Ninja (kf6-filesystem requires
  `ninja`) and ignores `%__builder`; `%kf6_use_make` before `%cmake_kf6` switches to make.
- **spec-cleaner** braces `%kf6_build`/`%kf6_install` (→ `%{kf6_build}`/`%{kf6_install}`),
  moves a `%if %{with released}` Source block below the dependencies and drops the blank line
  after the `%define`s: take its output, the expansion is the same.
- **No `gcc-c++` BuildRequires.** `kf6-extra-cmake-modules` Requires the C++ compiler
  `%cmake_kf6` uses (`gcc-c++`; on 16.1 `gcc15-c++`, which `%cmake_kf6` pins there). When
  upstream needs a newer compiler, add `gccNN-c++` and `gccNN-PIE` and pass
  `-DCMAKE_C_COMPILER:STRING=gcc-NN -DCMAKE_CXX_COMPILER:STRING=g++-NN` after `%cmake_kf6`,
  as kwin6 does.
- **Linking `Qt6::Sql` does not install a database driver.** Grep the source for the name
  passed to `QSqlDatabase::addDatabase` and add the matching `Requires:` (`QSQLITE` →
  `qt6-sql-sqlite`, `QPSQL` → `qt6-sql-postgresql`, `QMYSQL` → `qt6-sql-mysql`, `QODBC` →
  `qt6-sql-unixODBC`); add it as a BuildRequires too only if `%check` opens a database
  (kaidan).
- **QML imports:** when the QML is compiled into the binary (`qt_add_qml_module`, qrc),
  qml-autoreqprov cannot see it: `rpm -qpl <rpm> | grep -c '\.qml$'` of 0 means nothing was
  generated. Declare every module the sources import
  (`grep -rhoE '^import [A-Za-z.]+' --include='*.qml' .`), minus the package's own URI from
  `ecm_add_qml_module`/`qt_add_qml_module` — nothing provides that one (klevernotes:
  `org.kde.klevernotes`) — as `Requires: qt6qmlimport(<module>)` (imprint) or through the
  `*-imports` packages (klevernotes: `kf6-kirigami-imports`, `kirigami-addons6`,
  `qt6-declarative-imports`).
- **Translations**, when upstream installs catalogs: `%lang_package`; `%find_lang %{name}` with
  the flags for what it installs — `--all-name` when catalog names differ from `%{name}`,
  `--with-html` for KDocTools handbooks, `--with-qt` for Qt `.qm`, `--with-man` for localized
  man pages; and `%files lang -f %{name}.lang` (6 of the 8 sampled specs).
- **Sample before writing a new one:** `geectl remote cat KDE:Extra <pkg> <pkg>.spec` for two or three
  current specs — for layout, not correctness (klevernotes never builds its upstream
  `src/autotests`, and its version floors lag upstream's). This is in addition to the
  cross-distro survey of Core directive item 9, not a substitute.

Real case: transistor (sr#1381075) — declined for the generic `%cmake` macros, `%{_bindir}` /
`%{_datadir}` paths, plain `extra-cmake-modules`, a `gcc-c++` BuildRequires and a missing
SQL-driver `Requires`.
