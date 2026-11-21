#!/bin/bash
# Runs an unplaced write in a script that names the state directory.
echo ~/.local/state/opensuse-packaging/gate/obs/foo/devel:x.json | xargs cp /var/tmp/f.json
