#!/bin/bash
# A self-appending array that ends up merging a pool PR.
TEA=(tea)
TEA=("${TEA[@]}" pr)
"${TEA[@]}" merge --login src.opensuse.org --repo pool/gitoxide 5
