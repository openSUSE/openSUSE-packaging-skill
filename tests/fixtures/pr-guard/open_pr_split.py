import json
import urllib.request

# The pulls URL split by a backslash-newline inside the string, which Python joins.
req = urllib.request.Request(
    "https://src.opensuse.org/api/v1/repos/po\
ol/tesseract-ocr/pulls",
    data=json.dumps({"head": "someone:tess-88053-16.1", "base": "leap-16.1"}).encode(),
    headers={"Content-Type": "application/json"},
)
urllib.request.urlopen(req)
