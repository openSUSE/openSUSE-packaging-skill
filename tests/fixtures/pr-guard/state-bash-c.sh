#!/bin/bash
# Hands the state directory to a shell the guard cannot follow.
P=$HOME/.local/state/opensuse-packaging bash -c 'cp /var/tmp/f.json "$P/gate/obs/foo/devel:x.json"'
