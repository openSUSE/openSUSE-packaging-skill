#!/bin/sh
# A script written to open the PR by hand.
curl -sS -X POST -H "Content-Type: application/json" \
  "https://src.opensuse.org/api/v1/repos/pool/tesseract-ocr/pulls" \
  --data '{"head": "someone:tess-88053-16.1", "base": "leap-16.1", "title": "Update to 5.5.3"}'
