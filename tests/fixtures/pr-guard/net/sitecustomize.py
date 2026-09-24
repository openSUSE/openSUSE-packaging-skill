# Offline stand-in for pr-guard.py's live open-PR lookup, loaded through
# PYTHONPATH by test-pr-guard.sh. NET_STUB=<code> fails every request with that
# HTTP status; NET_STUB=<dir> answers the open-PR query for pool/<repo> with
# <dir>/<repo>.json, and any other URL fails the call loudly.
import io
import os
import re
import urllib.error
import urllib.request

_STUB = os.environ.get("NET_STUB", "")
_QUERY = re.compile(
    r"https://src\.opensuse\.org/api/v1/repos/pool/([^/]+)/pulls\?state=open&limit=50"
)


def _urlopen(url, *args, **kwargs):
    if _STUB.isdigit():
        raise urllib.error.HTTPError(url, int(_STUB), "stub", {}, io.BytesIO())
    m = _QUERY.fullmatch(url)
    if not m:
        raise AssertionError(f"unexpected lookup {url}")
    with open(os.path.join(_STUB, m.group(1) + ".json"), "rb") as fh:
        return io.BytesIO(fh.read())


if _STUB:
    urllib.request.urlopen = _urlopen
