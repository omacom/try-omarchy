#!/bin/bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: macos/publish-migration-exports.sh --outbox DIR --destination DIR

Publish the exports a guest left in its outbox for the Omarchy installer.
Each finished export is OUTBOX/<export id>/ with bundle.age and receipt.json.
An export is published only when its layout, size, receipt and SHA-256 all
check out, into DESTINATION/<export id>/ through a hidden folder and a rename,
never replacing one. Everything in OUTBOX is then removed, including partial
and rejected exports. Run it only while the VM is stopped.
EOF
}

fail() {
  printf 'publish-migration-exports: %s\n' "$*" >&2
  exit 1
}

note() {
  printf 'publish-migration-exports: %s\n' "$*" >&2
}

outbox='' destination=''
while (($#)); do
  case $1 in
    --outbox | --destination)
      (($# >= 2)) || { usage >&2; exit 64; }
      [[ $1 == --outbox ]] && outbox=$2 || destination=$2
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
[[ -n $outbox && -n $destination ]] || { usage >&2; exit 64; }

maximum_bundle_bytes=276018757632
maximum_receipt_bytes=1048576
uuid_pattern='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

[[ -e $outbox ]] || exit 0
[[ -d $outbox && ! -L $outbox && $(stat -f %u "$outbox") == "$(id -u)" ]] || fail "unsafe outbox: $outbox"
mkdir -p "$destination"
chmod 700 "$destination"
[[ -d $destination && ! -L $destination && $(stat -f %u "$destination") == "$(id -u)" ]] ||
  fail "unsafe destination: $destination"

sha256() {
  shasum -a 256 "$1" | cut -c1-64
}

receipt_field() { # receipt key type
  plutil -extract "$2" raw -expect "$3" -o - "$1" 2>/dev/null
}

check() { # folder name
  local folder=$1 name=$2 bundle receipt bytes
  [[ $name =~ $uuid_pattern ]] || { echo 'not an export'; return 1; }
  [[ -d $folder && ! -L $folder ]] || { echo 'not a folder'; return 1; }
  [[ $(ls -A "$folder" | sort | tr '\n' ' ') == 'bundle.age receipt.json ' ]] || { echo 'unexpected contents'; return 1; }
  bundle=$folder/bundle.age receipt=$folder/receipt.json
  [[ -f $bundle && ! -L $bundle && -f $receipt && ! -L $receipt ]] || { echo 'unsafe files'; return 1; }
  (($(stat -f %z "$receipt") <= maximum_receipt_bytes)) || { echo 'oversized receipt'; return 1; }
  [[ $(receipt_field "$receipt" schema string) == omarchy-migration/receipt/1 &&
     $(receipt_field "$receipt" export_id string) == "$name" &&
     $(receipt_field "$receipt" bundle.format string) == age-v1-scrypt ]] || { echo 'receipt does not match'; return 1; }
  bytes=$(receipt_field "$receipt" bundle.bytes integer) || { echo 'receipt has no size'; return 1; }
  [[ $bytes =~ ^[1-9][0-9]*$ ]] && ((bytes <= maximum_bundle_bytes)) &&
    [[ $(stat -f %z "$bundle") == "$bytes" ]] || { echo 'size differs from the receipt'; return 1; }
  [[ $(head -c 22 "$bundle") == age-encryption.org/v1 ]] || { echo 'not an age bundle'; return 1; }
  [[ $(sha256 "$bundle") == "$(receipt_field "$receipt" bundle.sha256 string)" ]] ||
    { echo 'digest differs from the receipt'; return 1; }
}

publish() { # folder name
  local folder=$1 name=$2 published staging
  published=$destination/$name
  [[ ! -e $published && ! -L $published ]] || { note "$name is already published"; return 0; }
  staging=$(mktemp -d "$destination/.$name.XXXXXX")
  if ! { { cp -c "$folder/bundle.age" "$folder/receipt.json" "$staging/" 2>/dev/null ||
           cp "$folder/bundle.age" "$folder/receipt.json" "$staging/"; } &&
         [[ $(sha256 "$staging/bundle.age") == "$(sha256 "$folder/bundle.age")" ]] &&
         chgrp "$(id -g)" "$staging" "$staging/bundle.age" "$staging/receipt.json" &&
         chmod 600 "$staging/bundle.age" "$staging/receipt.json" &&
         xattr -c "$staging/bundle.age" "$staging/receipt.json" &&
         [[ ! -e $published && ! -L $published ]] &&
         mv "$staging" "$published"; }; then
    rm -rf -- "$staging"
    fail "could not publish $name"
  fi
  echo "$published"
}

shopt -s nullglob dotglob
for folder in "$outbox"/*; do
  name=${folder##*/}
  if reason=$(check "$folder" "$name"); then
    publish "$folder" "$name"
  elif [[ $name != .* ]]; then
    note "skipped $name: $reason"
  fi
  rm -rf -- "$folder"
done
