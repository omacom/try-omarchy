#!/bin/bash
# Sourced by the sealed launcher. NAT never invokes privileged code.
QEMU_NETWORK_DIRECTORY=''
QEMU_NETWORK_STOP=''

qemu_network_validate() {
  QEMU_NETWORK_MODE=${OMARCHY_NETWORK_MODE:-nat}
  QEMU_NETWORK_INTERFACE=${OMARCHY_NETWORK_INTERFACE:-}
  QEMU_NETWORK_COMPATIBILITY=${OMARCHY_NETWORK_WIFI_COMPATIBILITY:-0}
  QEMU_NETWORK_SSH=${OMARCHY_NETWORK_BRIDGED_SSH:-0}
  case "$QEMU_NETWORK_MODE" in nat|bridged) ;; *) fail 'Network mode must be NAT or Bridged.' ;; esac
  if [[ $QEMU_NETWORK_MODE == bridged ]]; then
    [[ $QEMU_NETWORK_INTERFACE =~ ^[A-Za-z][A-Za-z0-9]{0,31}$ ]] || fail 'Choose an available bridge interface.'
    case "$QEMU_NETWORK_COMPATIBILITY:$QEMU_NETWORK_SSH" in 0:0|0:1|1:0|1:1) ;; *) fail 'Invalid bridged networking options.' ;; esac
  fi
}

qemu_network_mac() {
  # Keep the established NAT adapter identity. A bridge gets a private identity
  # tied to this disk instance, so copied/factory-reset disks get a fresh MAC.
  if [[ $QEMU_NETWORK_MODE == nat ]]; then
    printf '%s\n' '52:54:00:12:34:56'
    return
  fi
  python3 - "$QEMU_SELECTED_STORAGE_MODE" "$QEMU_SELECTED_DISK" "${QEMU_PERSISTENT_STORAGE_DISKS_ROOT:-}" <<'PY'
import json, os, secrets, stat, sys
mode, disk, disks_root = sys.argv[1:]
def new_mac():
    return '02:' + ':'.join(f'{byte:02x}' for byte in secrets.token_bytes(5))
if mode != 'persistent':
    print(new_mac())
    raise SystemExit
root = os.path.join(os.path.dirname(disks_root), 'network-identities')
try:
    os.mkdir(root, 0o700)
except FileExistsError:
    pass
info = os.lstat(root)
if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
    raise SystemExit('Unsafe network identity directory')
fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
opened = os.fstat(fd)
if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
    raise SystemExit("Network identity directory changed")
info = os.stat(disk, follow_symlinks=False)
identity = [info.st_dev, info.st_ino, info.st_birthtime]
name = os.path.basename(os.path.dirname(disk)) + '.json'
record = None
try:
    item = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
except FileNotFoundError:
    pass
else:
    info = os.fstat(item)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 512:
        os.close(item)
        raise SystemExit('Unsafe network identity record')
    with os.fdopen(item) as stream:
        record = json.load(stream)
if record is not None and record.get('disk') == identity:
    import re
    mac = record.get('mac', '')
    if not re.fullmatch(r'02(?::[0-9a-f]{2}){5}', mac):
        raise SystemExit('Invalid saved network identity')
else:
    mac = new_mac()
    temporary = name + '.' + secrets.token_hex(8)
    item = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
    with os.fdopen(item, 'w') as stream:
        json.dump({'disk': identity, 'mac': mac}, stream)
        stream.flush()
        os.fsync(stream.fileno())
    os.rename(temporary, name, src_dir_fd=fd, dst_dir_fd=fd)
    os.fsync(fd)
os.close(fd)
print(mac)
PY
}

qemu_network_start() {
  [[ $QEMU_NETWORK_MODE == bridged ]] || return 0
  local resources=$1
  local session=$2
  local app_pid=${OMARCHY_NETWORK_OWNER_PID:-$PPID}
  local supervisor="$resources/network/omarchy-network-supervisor"
  local server="$resources/network/socket_vmnet"
  local client="$resources/network/omarchy-network-client"
  [[ $app_pid =~ ^[0-9]+$ ]] || fail 'Invalid networking owner.'
  [[ -x $supervisor && ! -L $supervisor && -x $server && ! -L $server && -x $client && ! -L $client ]] || fail 'The bundled network helper is missing.'
  QEMU_NETWORK_STOP="$session/network.stop"
  # Replace the command-substitution shell so the client remains a direct child
  # of this launcher, as required by the daemon's process-chain authorization.
  if ! QEMU_NETWORK_DIRECTORY=$(exec "$client" start "$QEMU_NETWORK_INTERFACE" "$app_pid" "$QEMU_NETWORK_STOP" "$QEMU_NETWORK_COMPATIBILITY" 1); then
    fail 'Bridged networking could not start. Check networking helper approval or use Set Up / Repair Networking in the launch menu.'
  fi
  case "$QEMU_NETWORK_DIRECTORY" in /private/tmp/omarchy-network.??????) ;; *) fail 'Invalid network helper response.' ;; esac
  local attempt
  for ((attempt=0; attempt<200; attempt++)); do
    if [[ -f $QEMU_NETWORK_DIRECTORY/failed ]]; then
      cat "$QEMU_NETWORK_DIRECTORY/log" >&2
      fail 'The network helper could not start.'
    fi
    if [[ -f $QEMU_NETWORK_DIRECTORY/ready && -S $QEMU_NETWORK_DIRECTORY/network.sock ]]; then
      QEMU_NETWORK_NETDEV="stream,id=omarchy-net,server=off,addr.type=unix,addr.path=$QEMU_NETWORK_DIRECTORY/network.sock"
      return 0
    fi
    sleep 0.1
  done
  fail 'The network helper did not become ready.'
}

qemu_network_stop() {
  [[ -n $QEMU_NETWORK_DIRECTORY ]] || return 0
  [[ -n $QEMU_NETWORK_STOP ]] && : >"$QEMU_NETWORK_STOP"
  local attempt
  for ((attempt=0; attempt<80; attempt++)); do
    [[ -f $QEMU_NETWORK_DIRECTORY/done ]] && return 0
    if [[ -f $QEMU_NETWORK_DIRECTORY/failed ]]; then
      cat "$QEMU_NETWORK_DIRECTORY/log" >&2
      return 1
    fi
    [[ ! -d $QEMU_NETWORK_DIRECTORY ]] && return 0
    sleep 0.1
  done
  echo 'Networking cleanup is still pending. Check Wi-Fi compatibility restoration before another bridged launch.' >&2
  return 1
}
