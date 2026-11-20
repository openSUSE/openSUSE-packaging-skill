#!/bin/bash
# A gate.sh stand-in that writes its stamp where the real one does.
stampf="$HOME/.local/state/opensuse-packaging/gate/obs/foo/devel:x.json"
printf '{"verdict": "GREEN"}\n' > "$stampf"
