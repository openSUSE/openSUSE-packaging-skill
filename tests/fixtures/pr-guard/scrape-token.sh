#!/bin/sh
# Scrapes the Gitea token out of tea's config, as an agent did in the field.
grep -A3 src.opensuse.org ~/.config/tea/config.yml | awk '/token/ {print $2}'
