#!/usr/bin/env python3
"""Non-network unit tests for the update-checker helpers.

Covers the class of misses that used to hide packages like openai-codex:
tag-prefix extraction (digit-after-prefix), Anitya same-name collisions,
and scoped npm URL parsing. Run from anywhere:
    python3 tests/test-update-checkers.py
"""
import os
import sys
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))

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


if __name__ == "__main__":
    unittest.main()
