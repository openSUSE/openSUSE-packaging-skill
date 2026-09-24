#!/usr/bin/env python3
# A report that only reads PRs; its own --json flag is no request body.
import argparse
import json
import urllib.request

API = "https://src.opensuse.org/api/v1"
REPO = "products/SLFO"

p = argparse.ArgumentParser()
p.add_argument("--json", action="store_true", help="emit JSON")
p.add_argument("--state", default="open")
a = p.parse_args()
with urllib.request.urlopen(f"{API}/repos/{REPO}/pulls?state={a.state}") as r:
    prs = json.load(r)
print(json.dumps(prs) if a.json else len(prs))
