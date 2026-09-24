# A script written to open the PR by hand, through curl.
system("curl", "-sS", "-X", "POST", "https://src.opensuse.org/api/v1/repos/pool/tesseract-ocr/pulls",
    "--data", '{"head": "someone:tess-88053-16.1", "base": "leap-16.1"}');
