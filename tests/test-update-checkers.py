#!/usr/bin/env python3
"""Unit tests for the update-checker helpers.

No test touches the network: lookups are stubbed, and the two subprocess
tests run the sweep with every source disabled or behind a dead proxy.

Covers the class of misses that used to hide packages like openai-codex:
tag-prefix extraction (digit-after-prefix), Anitya same-name collisions,
and scoped npm URL parsing. Run from anywhere:
    python3 tests/test-update-checkers.py
"""
import http.client
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "skills", "opensuse-packaging", "scripts"))

import _anitya  # noqa: E402
import _forges  # noqa: E402


GITHUB_CODEX = {
    "id": 387692,
    "name": "codex",
    "homepage": "https://github.com/openai/codex",
    "backend": "GitHub",
    "version": "0.149.0-alpha.5",
    "stable_versions": ["0.148.0", "0.147.0"],
}
PYPI_CODEX = {
    "id": 127434,
    "name": "codex",
    "homepage": "https://pypi.org/project/codex/0.5.0",
    "backend": "PyPI",
    "version": "2.2.8",
    "stable_versions": ["2.2.8", "2.2.7"],
}


def _fake_anitya_get(url):
    """JSON stand-in for release-monitoring.org; no network."""
    if "/packages/" in url:
        return {"items": []}
    if "/projects/" in url and "name=openai-codex" in url:
        return {"items": []}
    if "/projects/" in url and "name=codex" in url:
        return {"items": [GITHUB_CODEX, PYPI_CODEX]}
    if "/projects/" in url and "name=onlyone" in url:
        return {"items": [{
            "name": "onlyone",
            "homepage": "https://example.com/onlyone",
            "stable_versions": ["1.2.3"],
        }]}
    return {"items": []}


class TagPrefixTests(unittest.TestCase):
    SRC = ("https://github.com/openai/codex/archive/refs/tags/"
           "rust-v%{version}.tar.gz#/codex-rust-v%{version}.tar.gz")

    def test_extracts_literal_prefix_before_version(self):
        self.assertEqual(_forges.tag_prefix(self.SRC), "rust-v")
        self.assertEqual(
            _forges.tag_prefix(
                "https://github.com/foo/bar/archive/refs/tags/v%{version}.tar.gz"),
            "v")
        self.assertIsNone(_forges.tag_prefix("https://github.com/openai/codex"))

    def test_digit_after_prefix_keeps_rust_v_drops_rusty_v8(self):
        p = "rust-v"
        self.assertTrue(_forges.tag_matches_prefix("rust-v0.148.0", p))
        self.assertFalse(_forges.tag_matches_prefix("rusty-v8-v150.4.0", p))
        self.assertFalse(_forges.tag_matches_prefix(
            "rust-vrust-v0.147.0-alpha.9", p))
        self.assertTrue(_forges.tag_matches_prefix("v1.2.3", "v"))
        self.assertFalse(_forges.tag_matches_prefix("version-1", "v"))
        # no declared prefix → no filter
        self.assertTrue(_forges.tag_matches_prefix("rusty-v8-v150.4.0", None))
        self.assertTrue(_forges.tag_matches_prefix("rusty-v8-v150.4.0", ""))


class AnityaCollisionTests(unittest.TestCase):
    def test_multi_project_without_homepage_is_unknown(self):
        with mock.patch.object(_anitya, "_get", side_effect=_fake_anitya_get):
            self.assertEqual(_anitya.latest_stable("codex"), (None, None))

    def test_homepage_picks_github_not_pypi(self):
        with mock.patch.object(_anitya, "_get", side_effect=_fake_anitya_get):
            self.assertEqual(
                _anitya.latest_stable(
                    "openai-codex",
                    homepage="https://github.com/openai/codex"),
                ("0.148.0", "homepage"))
            self.assertEqual(
                _anitya.latest_stable(
                    "codex",
                    homepage="https://github.com/openai/codex/"),
                ("0.148.0", "homepage"))

    def test_unique_name_match_still_works(self):
        with mock.patch.object(_anitya, "_get", side_effect=_fake_anitya_get):
            self.assertEqual(
                _anitya.latest_stable("onlyone"),
                ("1.2.3", "name-match"))

    def test_search_name_from_github_homepage(self):
        self.assertEqual(
            _anitya.search_name_from_homepage("https://github.com/openai/codex"),
            "codex")


class NpmUrlTests(unittest.TestCase):
    def test_scoped_npmjs_com(self):
        self.assertEqual(
            _forges.parse_forge("https://www.npmjs.com/package/@openai/codex"),
            ("npm", None, "@openai/codex"))

    def test_scoped_registry_slash(self):
        self.assertEqual(
            _forges.parse_forge(
                "https://registry.npmjs.org/@openai/codex/-/codex-0.148.0.tgz"),
            ("npm", None, "@openai/codex"))

    def test_scoped_registry_urlencoded(self):
        self.assertEqual(
            _forges.parse_forge("https://registry.npmjs.org/@openai%2Fcodex"),
            ("npm", None, "@openai/codex"))

    def test_github_plus_npm_source_and_companions(self):
        url = "https://github.com/openai/codex"
        src = ("https://github.com/openai/codex/archive/refs/tags/"
               "rust-v%{version}.tar.gz")
        got = _forges.pick_forges(url, src)
        self.assertIn(("github", "openai", "codex", False), got)
        self.assertIn(("npm", None, "@openai/codex", True), got)
        self.assertIn(("npm", None, "codex", True), got)


class SourceOutageTests(unittest.TestCase):
    """A source being down must degrade the run, never decide it wrongly."""

    PYPI_SRC = "https://files.pythonhosted.org/packages/source/f/foo/foo-1.0.tar.gz"
    GH_ROW = ("github", "someone", "foo", False, {"latest_stable": ("2.0", None)})
    PYPI_ROW = ("pypi", None, "foo", False, {"latest_stable": ("1.0", None)})

    def test_registry_down_while_another_forge_answers_is_no_answer(self):
        # pythonhosted Source0 => PyPI is the authority. It raised; GitHub
        # answered with a newer tag. That tag is not a consumable release.
        self.assertTrue(_forges.authority_unanswered(
            self.PYPI_SRC, [self.GH_ROW], [("pypi", None, "foo")]))

    def test_registry_answered_wins_over_a_stale_failure_entry(self):
        # The registry is in BOTH lists (e.g. one companion probe raised while
        # the real one answered): answering must win.
        self.assertFalse(_forges.authority_unanswered(
            self.PYPI_SRC, [self.PYPI_ROW, self.GH_ROW],
            [("pypi", None, "foo")]))

    def test_no_registry_source0_returns_false_before_looking_at_failures(self):
        self.assertFalse(_forges.authority_unanswered(
            "", [], [("pypi", None, "foo")]))

    def test_non_registry_source0_has_no_authority_to_lose(self):
        # A plain GitHub archive Source0: any forge may answer; a failure
        # elsewhere is an ordinary per-source degrade, not an authority gap.
        self.assertFalse(_forges.authority_unanswered(
            "https://github.com/someone/foo/archive/v%{version}.tar.gz",
            [self.GH_ROW], [("npm", None, "foo")]))

    def test_registry_absent_but_not_probed_is_not_an_outage(self):
        # Nothing failed — the registry simply was not among the picked
        # sources. Silence is not an outage.
        self.assertFalse(_forges.authority_unanswered(
            self.PYPI_SRC, [self.GH_ROW], []))


class TransportVsFactTests(unittest.TestCase):
    """Only a source that could not ANSWER is an outage."""

    def test_connection_and_timeout_are_outages(self):
        self.assertTrue(_forges.is_transport_error(
            urllib.error.URLError(ConnectionRefusedError(111, "refused"))))
        self.assertTrue(_forges.is_transport_error(TimeoutError()))
        self.assertTrue(_forges.is_transport_error(
            http.client.IncompleteRead(b"")))

    def test_non_json_body_is_an_outage(self):
        # A maintenance/gateway HTML page served with 200 — the usual way a
        # public API goes down.
        self.assertTrue(_forges.is_transport_error(
            json.JSONDecodeError("Expecting value", "<html>", 0)))

    def test_5xx_and_429_are_outages_but_404_is_an_answer(self):
        def http_err(code):
            return urllib.error.HTTPError("u", code, "m", None, None)
        for code in (429, 500, 502, 503, 504):
            self.assertTrue(_forges.is_transport_error(http_err(code)), code)
        for code in (404, 422, 410):
            self.assertFalse(_forges.is_transport_error(http_err(code)), code)

    def test_no_releases_is_an_answer_not_an_outage(self):
        # probe_github/probe_pypi raise this for tagless mirrors and
        # prerelease-only projects. Counting it as an outage would put every
        # large sweep permanently in the degraded state.
        self.assertFalse(_forges.is_transport_error(
            RuntimeError("github a/b: no releases and no datable tags")))


class MacroSourceTests(unittest.TestCase):
    """An unexpanded RPM macro is not a registry identity."""

    def test_macro_npm_source0_has_no_authority(self):
        self.assertIsNone(_forges.source_registry(
            "https://registry.npmjs.org/%{name}/-/%{name}-%{version}.tgz"))

    def test_macro_crates_source0_has_no_authority(self):
        self.assertIsNone(_forges.source_registry(
            "https://static.crates.io/crates/%{name}/%{name}-%{version}.crate"))

    def test_macro_source0_cannot_manufacture_an_outage(self):
        # Regression guard: such a target can never answer, so treating it as
        # the authority would suppress the package on every sweep, forever.
        self.assertFalse(_forges.authority_unanswered(
            "https://registry.npmjs.org/%{name}/-/%{name}-%{version}.tgz",
            [("github", "someone", "thing", False,
              {"latest_stable": ("2.0", None)})],
            [("npm", None, "%{name}")]))

    def test_a_real_registry_name_still_resolves(self):
        self.assertEqual(
            _forges.source_registry(
                "https://files.pythonhosted.org/packages/source/f/foo/foo-1.0.tar.gz"),
            ("pypi", None, "foo"))


class SweepCoverageTests(unittest.TestCase):
    """outdated.py must report what did NOT run, and say so in its exit code."""

    SCRIPT = os.path.join(HERE, "..", "skills", "opensuse-packaging", "scripts", "outdated.py")

    def _run(self, *flags, names=("somepackage",), offline=False):
        env = dict(os.environ)
        if offline:
            # Hermetic outage: urllib honours these, so the Repology fetch
            # fails without touching the network (and without a live
            # repology.org turning this into a full paginated download).
            for k in ("HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "no_proxy"):
                env.pop(k, None)
            env.update(http_proxy="http://127.0.0.1:1",
                       https_proxy="http://127.0.0.1:1")
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as fh:
            fh.write("".join(f"{n}\n" for n in names))
            path = fh.name
        try:
            return subprocess.run(
                [sys.executable, self.SCRIPT, "--names", path, *flags],
                capture_output=True, text=True, timeout=120, env=env)
        finally:
            os.unlink(path)

    def test_all_sources_skipped_by_flag_is_full_coverage(self):
        r = self._run("--no-repology", "--no-anitya", "--no-forge",
                      "--no-factory-check")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("# COVERAGE: complete", r.stdout)
        self.assertIn("repology (--no-repology)", r.stdout)

    def test_unreachable_repology_degrades_instead_of_aborting(self):
        r = self._run("--no-anitya", "--no-forge", "--no-factory-check",
                      offline=True)
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertIn("# COVERAGE: DEGRADED", r.stdout)
        self.assertIn("repology UNREACHABLE", r.stdout)
        self.assertIn("WARNING: Repology unreachable", r.stderr)
        self.assertNotIn("Traceback", r.stderr)

    def test_non_json_repology_body_degrades_instead_of_aborting(self):
        # The most common outage shape: HTTP 200 with an HTML gateway page.
        with tempfile.TemporaryDirectory() as d:
            stub = os.path.join(d, "sitecustomize.py")
            with open(stub, "w") as fh:
                fh.write(
                    "import io, urllib.request\n"
                    "class _R(io.BytesIO):\n"
                    "    def __enter__(self): return self\n"
                    "    def __exit__(self, *a): return False\n"
                    "urllib.request.urlopen = lambda *a, **k: "
                    "_R(b'<html>502 Bad Gateway</html>')\n")
            env = dict(os.environ, PYTHONPATH=d)
            with tempfile.NamedTemporaryFile("w", suffix=".txt",
                                             delete=False) as fh:
                fh.write("somepackage\n")
                path = fh.name
            try:
                r = subprocess.run(
                    [sys.executable, self.SCRIPT, "--names", path,
                     "--no-anitya", "--no-forge", "--no-factory-check"],
                    capture_output=True, text=True, timeout=120, env=env)
            finally:
                os.unlink(path)
        self.assertNotIn("Traceback", r.stderr)
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertIn("# COVERAGE: DEGRADED", r.stdout)

    def test_empty_name_set_is_degraded_not_clean(self):
        # The oldest trap in the sweep: nothing was checked, so it looks clean.
        r = self._run("--no-repology", "--no-anitya", "--no-forge",
                      "--no-factory-check", names=())
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertIn("NO PACKAGE NAMES", r.stdout)


class ForgeWiringTests(unittest.TestCase):
    """End-to-end wiring of the three-way forge classification.

    The helpers are unit-tested above; these drive the real scripts with every
    network call stubbed, because the buckets are assigned in a closure inside
    a script and a mutation there is otherwise invisible.
    """

    OUTDATED = os.path.join(HERE, "..", "skills", "opensuse-packaging", "scripts", "outdated.py")
    PROBE = os.path.join(HERE, "..", "skills", "opensuse-packaging", "scripts", "upstream-probe.py")

    SPEC = ("Name:           pkg-a\n"
            "Version:        1.0\n"
            "URL:            https://github.com/someone/thing\n"
            "Source0:        https://github.com/someone/thing/archive/"
            "refs/tags/v%{version}.tar.gz\n")
    # Source0 served by a registry: PyPI is the authority for this one.
    SPEC_PYPI = ("Name:           pkg-b\n"
                 "Version:        1.0\n"
                 "URL:            https://github.com/someone/thing\n"
                 "Source0:        https://files.pythonhosted.org/packages/"
                 "source/p/pkg-b/pkg-b-1.0.tar.gz\n")

    STUB = '''
import io, json, os, subprocess, urllib.error, urllib.request

MODE = os.environ["FORGE_MODE"]
SPEC = os.environ["FORGE_SPEC"]

class _R(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *a): return False

_real_run = subprocess.run
def _run(cmd, *a, **k):
    if cmd and cmd[0] == "osc":
        return subprocess.CompletedProcess(cmd, 0, SPEC, "")
    if cmd and cmd[0] == "gh":
        # force the anonymous HTTP path so urlopen below is the only source
        return subprocess.CompletedProcess(cmd, 1, "", "not logged in")
    return _real_run(cmd, *a, **k)
subprocess.run = _run

def _urlopen(req, *a, **k):
    url = getattr(req, "full_url", req)
    if "repology.org" in url:
        if MODE == "repology_partial":
            # first page answers, second dies: the downloaded page must survive
            if "/?" in url and "/projects/?" in url:
                page = {f"p{i:04d}": [{"repo": "opensuse_tumbleweed",
                                       "srcname": "pkg-a", "version": "1.0",
                                       "status": "outdated"}]
                        for i in range(200)}
                return _R(json.dumps(page).encode())
            raise urllib.error.URLError(ConnectionRefusedError(111, "refused"))
        raise urllib.error.URLError(ConnectionRefusedError(111, "refused"))
    if "pypi.org" in url or "pythonhosted" in url:
        if MODE == "authority_down":
            raise urllib.error.HTTPError(url, 403, "blocked", None, None)
        if MODE == "authority_404":
            raise urllib.error.HTTPError(url, 404, "no such project",
                                         None, None)
        return _R(json.dumps({"info": {"version": "1.0"}, "releases": {}}).encode())
    if "release-monitoring.org" in url:
        return _R(json.dumps({"items": []}).encode())
    if "api.github.com" in url:
        if MODE == "authority_404":
            if "/releases" in url:
                return _R(json.dumps([{ "tag_name": "v2.0",
                                        "prerelease": False, "draft": False,
                                        "published_at": "2026-09-01T00:00:00Z"}]).encode())
            if "/commits/" in url or "/git/refs" in url or "/tags" in url:
                return _R(json.dumps({"commit": {"committer": {
                    "date": "2026-09-01T00:00:00Z"}}}).encode())
            return _R(b"{}")
        if MODE == "down":
            raise urllib.error.HTTPError(url, 403, "rate limited", None, None)
        if MODE in ("nodata", "authority_down"):
            if "/releases" in url or "/tags" in url:
                return _R(b"[]")
            return _R(b"{}")
    return _R(b"[]")
urllib.request.urlopen = _urlopen
'''

    def _sweep(self, mode, spec=None, flags=("--no-repology", "--no-anitya")):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "sitecustomize.py"), "w") as fh:
                fh.write(self.STUB)
            names = os.path.join(d, "names.txt")
            with open(names, "w") as fh:
                fh.write("pkg-a\n")
            env = dict(os.environ, PYTHONPATH=d, FORGE_MODE=mode,
                       FORGE_SPEC=spec or self.SPEC)
            for k in ("HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "no_proxy"):
                env.pop(k, None)
            return subprocess.run(
                [sys.executable, self.OUTDATED, "--names", names, *flags],
                capture_output=True, text=True, timeout=120, env=env)

    def test_forge_outage_degrades_coverage(self):
        r = self._sweep("down")
        self.assertNotIn("Traceback", r.stderr)
        self.assertIn("UNREACHABLE", r.stdout)
        self.assertIn("# COVERAGE: DEGRADED", r.stdout)
        self.assertEqual(r.returncode, 3, r.stdout)

    def test_tagless_upstream_is_not_an_outage(self):
        r = self._sweep("nodata")
        self.assertNotIn("Traceback", r.stderr)
        self.assertIn("no usable release", r.stdout)
        self.assertNotIn("# COVERAGE: DEGRADED", r.stdout)
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_source0_registry_down_is_reported_and_degrades(self):
        r = self._sweep("authority_down", spec=self.SPEC_PYPI)
        self.assertNotIn("Traceback", r.stderr)
        self.assertIn("Source0 registry is down", r.stdout)
        self.assertIn("# COVERAGE: DEGRADED", r.stdout)
        self.assertEqual(r.returncode, 3, r.stdout)


    # A spec whose URL:/Source0: resolve to no forge at all.
    SPEC_UNMAPPED = ("Name:           pkg-c\n"
                     "Version:        1.0\n"
                     "URL:            https://example.invalid/pkg-c\n"
                     "Source0:        pkg-c-1.0.tar.gz\n")

    def test_unresolvable_forge_lands_in_its_own_bucket(self):
        r = self._sweep("nodata", spec=self.SPEC_UNMAPPED)
        self.assertNotIn("Traceback", r.stderr)
        self.assertIn("no forge resolvable", r.stdout)
        self.assertNotIn("no usable release", r.stdout)
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_partial_repology_pages_are_kept(self):
        r = self._sweep("repology_partial", flags=("--no-anitya", "--no-forge",
                                                   "--no-factory-check"))
        self.assertNotIn("Traceback", r.stderr)
        self.assertRegex(r.stderr, r"the [1-9]\d* project\(s\) already downloaded")
        # The warning interpolates the count BEFORE a discard would happen, so
        # it reads the same either way: the kept pages are only visible as the
        # candidate they produce.
        self.assertIn("pkg-a", r.stdout)
        self.assertEqual(r.returncode, 3, r.stdout)

    def test_probe_still_gives_a_verdict_when_the_registry_merely_404s(self):
        # Mirror of the authority test: a 404 is the registry ANSWERING, so a
        # verdict is owed. Without this, "treat every failure as transport"
        # passes unnoticed and real updates are suppressed.
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "sitecustomize.py"), "w") as fh:
                fh.write(self.STUB)
            spec = os.path.join(d, "pkg-b.spec")
            with open(spec, "w") as fh:
                fh.write(self.SPEC_PYPI)
            env = dict(os.environ, PYTHONPATH=d, FORGE_MODE="authority_404",
                       FORGE_SPEC=self.SPEC_PYPI)
            r = subprocess.run([sys.executable, self.PROBE, "--spec", spec],
                               capture_output=True, text=True, timeout=120,
                               env=env)
        self.assertNotIn("Traceback", r.stderr)
        self.assertNotEqual(r.returncode, 2, r.stdout + r.stderr)

    def test_probe_refuses_a_verdict_when_the_registry_is_down(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "sitecustomize.py"), "w") as fh:
                fh.write(self.STUB)
            spec = os.path.join(d, "pkg-b.spec")
            with open(spec, "w") as fh:
                fh.write(self.SPEC_PYPI)
            env = dict(os.environ, PYTHONPATH=d, FORGE_MODE="authority_down",
                       FORGE_SPEC=self.SPEC_PYPI)
            r = subprocess.run([sys.executable, self.PROBE, "--spec", spec],
                               capture_output=True, text=True, timeout=120,
                               env=env)
        self.assertNotIn("Traceback", r.stderr)
        # 2 = probe failed; never 0 (CURRENT) or 1 (UPDATE-CANDIDATE)
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("serves Source0", r.stderr)


class GhLaunderingTests(unittest.TestCase):
    """A gh failure must not read as "this repo has no releases"."""

    def test_gh_transport_failure_is_an_outage(self):
        self.assertTrue(_forges.is_transport_error(
            _forges.SourceDown("gh api repos/x/y: HTTP 403 rate limit")))

    def test_gh_timeout_is_an_outage(self):
        self.assertTrue(_forges.is_transport_error(
            subprocess.TimeoutExpired(["gh"], 30)))

    def test_403_is_an_outage_on_every_forge(self):
        self.assertTrue(_forges.is_transport_error(
            urllib.error.HTTPError("u", 403, "rate limited", None, None)))

    def test_plain_runtimeerror_is_still_an_answer(self):
        self.assertFalse(_forges.is_transport_error(
            RuntimeError("github x/y: no releases and no datable tags")))


class GhApiBranchTests(unittest.TestCase):
    """The `gh api` path — the DEFAULT for anyone with gh authenticated.

    `_forges.py` recommends authenticating (5000 req/h vs 60), so this branch
    is the one most real runs take, and every transport failure in it has to
    become SourceDown or it is indistinguishable from "this repo has no
    releases" (which silently reads as a clean sweep).
    """

    def _gh(self, **run_kw):
        return mock.patch.object(_forges, "_GH", True), \
               mock.patch.object(_forges.subprocess, "run", **run_kw)

    def test_timeout_becomes_source_down(self):
        gh, run = self._gh(side_effect=subprocess.TimeoutExpired(["gh"], 30))
        with gh, run:
            with self.assertRaises(_forges.SourceDown):
                _forges.gh_json("repos/x/y/tags")

    def test_rate_limit_becomes_source_down(self):
        gh, run = self._gh(return_value=subprocess.CompletedProcess(
            ["gh"], 1, "", "HTTP 403: API rate limit exceeded"))
        with gh, run:
            with self.assertRaises(_forges.SourceDown):
                _forges.gh_json("repos/x/y/tags")

    def test_non_json_stdout_becomes_source_down(self):
        gh, run = self._gh(return_value=subprocess.CompletedProcess(
            ["gh"], 0, "<html>gateway</html>", ""))
        with gh, run:
            with self.assertRaises(_forges.SourceDown):
                _forges.gh_json("repos/x/y/tags")

    def test_404_is_still_a_fact_not_an_outage(self):
        # The other half of the contract: absence must stay absence.
        gh, run = self._gh(return_value=subprocess.CompletedProcess(
            ["gh"], 1, "", "gh: Not Found (HTTP 404)"))
        with gh, run:
            self.assertIsNone(_forges.gh_json("repos/x/y/tags"))

    def test_success_still_parses(self):
        gh, run = self._gh(return_value=subprocess.CompletedProcess(
            ["gh"], 0, '[{"name": "v1.0"}]', ""))
        with gh, run:
            self.assertEqual(_forges.gh_json("repos/x/y/tags"),
                             [{"name": "v1.0"}])

    def test_every_gh_failure_mode_is_seen_as_an_outage(self):
        # gh_json raising is only half the fix: the classifier must also
        # agree, or the caller files it as "answered, nothing there".
        for exc in (subprocess.TimeoutExpired(["gh"], 30),
                    _forges.SourceDown("gh api x: HTTP 403")):
            self.assertTrue(_forges.is_transport_error(exc), exc)


class AnityaGuardTests(unittest.TestCase):
    """release-monitoring.org must never abort a sweep, whatever it returns."""

    def _get_with_body(self, body):
        class _R(io.BytesIO):
            def __enter__(self): return self
            def __exit__(self, *a): return False
        with mock.patch.object(_anitya.urllib.request, "urlopen",
                               return_value=_R(body)):
            return _anitya._get("https://release-monitoring.org/api/v2/projects/")

    def test_plain_text_waf_body_is_an_anitya_error(self):
        # Not HTML, so the existing `<`-prefix anti-bot guard does not see it.
        with self.assertRaises(_anitya.AnityaError):
            self._get_with_body(b"error code: 1015")

    def test_empty_body_is_an_anitya_error(self):
        with self.assertRaises(_anitya.AnityaError):
            self._get_with_body(b"")

    def test_list_payload_is_an_anitya_error(self):
        # Caught for real: this used to escape as AttributeError from inside
        # a thread pool and abort the whole run.
        with self.assertRaises(_anitya.AnityaError):
            self._get_with_body(b"[]")

    def test_truncated_read_is_an_anitya_error(self):
        # IncompleteRead is not an OSError; without the HTTPException catch it
        # escapes AnityaError and aborts the whole sweep.
        class _R:
            def __enter__(self): return self
            def __exit__(self, *a): return False
            def read(self): raise http.client.IncompleteRead(b"{", 500)
        with mock.patch.object(_anitya.urllib.request, "urlopen",
                               return_value=_R()):
            with self.assertRaises(_anitya.AnityaError):
                _anitya._get("https://release-monitoring.org/api/v2/projects/")

    def test_normal_payload_still_parses(self):
        self.assertEqual(self._get_with_body(b'{"items": []}'), {"items": []})


class ExceptTupleParityTests(unittest.TestCase):
    """The two commands must catch the same probe failures.

    _forges.py exists so outdated.py and upstream-probe.py cannot drift; a
    difference here means one of them crashes where the other degrades.
    """

    def _tuple(self, path, needle):
        src = open(os.path.join(HERE, "..", "skills", "opensuse-packaging", "scripts", path)).read()
        i = src.index(needle)
        frag = src[i:src.index(" as e:", i)]
        return sorted(t.strip() for t in
                      frag[frag.index("(") + 1:frag.rindex(")")].split(","))

    def test_probe_failure_tuples_are_identical(self):
        needle = "except (OSError, RuntimeError, ValueError"
        got = self._tuple("outdated.py", needle)
        self.assertEqual(got, self._tuple("upstream-probe.py", needle))
        # Parity alone survives dropping a member from BOTH tuples, so pin the
        # one that is easy to lose: it is not an OSError.
        self.assertIn("http.client.HTTPException", got)

if __name__ == "__main__":
    unittest.main()
