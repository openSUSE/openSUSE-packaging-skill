#!/bin/bash
# An array that appends to itself, as download_files builds its curl call.
CURL=(/usr/bin/curl --location --silent)
[ -n "$1" ] && CURL=("${CURL[@]}" -4)
[ -n "$2" ] && CURL=("${CURL[@]}" --insecure)
"${CURL[@]}" -o /dev/null https://example.org/file.tar.gz
