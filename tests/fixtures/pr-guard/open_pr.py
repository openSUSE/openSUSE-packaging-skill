import json
import urllib.request

req = urllib.request.Request(
    "https://src.opensuse.org/api/v1/repos/pool/tesseract-ocr/pulls",
    data=json.dumps({"head": "someone:tess-88053-16.1", "base": "leap-16.1"}).encode(),
    headers={"Content-Type": "application/json"},
)
urllib.request.urlopen(req)
