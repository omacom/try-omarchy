#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd -P)
contents=${1:?app Contents directory required}
header_dir=$(mktemp -d /private/tmp/omarchy-network-build.XXXXXX)
trap 'rm -rf "$header_dir"' EXIT
python3 - "$contents" "$header_dir/network-build.h" <<'PY'
import hashlib,json,os,re,subprocess,sys
from pathlib import Path
contents=Path(sys.argv[1])
service=os.environ.get("OMARCHY_NETWORK_SERVICE_NAME", "dev.tryomarchy.network")
if not re.fullmatch(r"[A-Za-z0-9]+(?:[.][A-Za-z0-9-]+)+", service): raise SystemExit("Invalid networking service name")
values={"NETWORK_SERVICE_NAME": service}
for key,path in [('CLIENT_REQUIREMENT',contents/'Resources/network/omarchy-network-client')]:
    output=subprocess.run(['codesign','-d','--verbose=4',str(path)],check=True,capture_output=True,text=True).stderr
    value=re.search(r'^CDHash=([0-9a-f]{40})$',output,re.M)
    if not value: raise SystemExit('Missing signed helper identity')
    values[key]='cdhash H"'+value[1]+'"'
for key,name in [('SERVER_SHA256','socket_vmnet'),('SUPERVISOR_SHA256','omarchy-network-supervisor')]:
    values[key]=hashlib.sha256((contents/'Resources/network'/name).read_bytes()).hexdigest()
Path(sys.argv[2]).write_text(''.join('#define '+key+' '+json.dumps(value)+'\n' for key,value in values.items()))
PY
/usr/bin/clang -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations -fblocks -mmacosx-version-min=15.0 \
  -I "$header_dir" -framework CoreFoundation -framework SystemConfiguration \
  "$root/daemon.c" -o "$contents/MacOS/omarchy-network-daemon"
