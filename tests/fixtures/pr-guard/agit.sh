#!/bin/sh
# Opens a PR through AGit: the ref name is the request.
git push origin HEAD:refs/for/leap-16.0 -o topic=tess-5.5.3
