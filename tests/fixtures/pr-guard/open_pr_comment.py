import json
import urllib.request

# A comment that ends in a backslash does not continue onto the next line: \
req = urllib.request.Request(
    "https://src.opensuse.org/api/v1/repos/pool/tesseract-ocr/pulls",
    data=json.dumps({"head": "someone:tess-88053-16.1", "base": "leap-16.1"}).encode(),
    headers={"Content-Type": "application/json"},
)
urllib.request.urlopen(req)
