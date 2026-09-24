await fetch("https://src.opensuse.org/api/v1/repos/pool/tesseract-ocr/pulls", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ head: "someone:tess-88053-16.1", base: "leap-16.1" }),
})
