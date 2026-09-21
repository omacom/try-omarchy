#!/bin/bash

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd -P)
native_dir=$(cd "$test_dir/.." && pwd -P)
verifier="$native_dir/verify-macos-compatibility.sh"

fail() {
  echo "macos-compatibility.test: $*" >&2
  exit 1
}

assert_fails_with() {
  local expected=$1
  shift
  local output
  if output=$("$@" 2>&1); then
    fail "command unexpectedly succeeded: $*"
  fi
  [[ $output == *"$expected"* ]] || \
    fail "failure did not contain [$expected]: $output"
}

test_root=$(mktemp -d /private/tmp/omarchy-macos-compatibility-test.XXXXXX)
case "$test_root" in
  /private/tmp/omarchy-macos-compatibility-test.??????) ;;
  *) fail "unexpected test root: $test_root" ;;
esac
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  rm -rf -- "$test_root"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fixture_root="$test_root/fixtures with spaces"
mkdir -p "$fixture_root/nested"
printf '%s\n' 'not a Mach-O image' >"$fixture_root/readme.txt"

clang -arch arm64 -mmacosx-version-min=26.0 -x c - \
  -o "$fixture_root/nested/compatible" <<'EOF'
int main(void) { return 0; }
EOF

clang -arch arm64 -mmacosx-version-min=26.0 \
  -Werror=unguarded-availability-new -Wl,-undefined,dynamic_lookup -x c - \
  -o "$fixture_root/nested/guarded-weak-import" <<'EOF'
#include <stddef.h>
extern char *weak_strchrnul(const char *, int)
    __asm("_strchrnul") __attribute__((weak_import));
int main(void) {
    if (weak_strchrnul != NULL) {
        return weak_strchrnul("compatibility", 'x') == NULL;
    }
    return 0;
}
EOF

"$verifier" "$fixture_root" >/dev/null

clang -arch arm64 -mmacosx-version-min=26.1 -x c - \
  -o "$fixture_root/nested/too-new" <<'EOF'
int main(void) { return 0; }
EOF
assert_fails_with 'requires macOS 26.1' "$verifier" "$fixture_root"
rm -f "$fixture_root/nested/too-new"

clang -arch arm64 -mmacosx-version-min=26.0 \
  -Wl,-undefined,dynamic_lookup -x c - \
  -o "$fixture_root/nested/strong-import" <<'EOF'
#include <stddef.h>
extern char *strchrnul(const char *, int);
int main(void) { return strchrnul("compatibility", 'x') == NULL; }
EOF
"$verifier" "$fixture_root" >/dev/null
rm -f "$fixture_root/nested/strong-import"

clang -arch arm64 -mmacosx-version-min=26.0 -x c - \
  -o "$test_root/arm64-compatible" <<'EOF'
int main(void) { return 0; }
EOF
clang -arch x86_64 -mmacosx-version-min=26.1 -x c - \
  -o "$test_root/x86_64-too-new" <<'EOF'
int main(void) { return 0; }
EOF
lipo -create "$test_root/arm64-compatible" "$test_root/x86_64-too-new" \
  -output "$fixture_root/nested/universal-too-new"
assert_fails_with 'requires macOS 26.1' "$verifier" "$fixture_root"

# Reject older hosts before app assembly or launcher state handling begins.
mkdir "$test_root/old-host-bin"
cat >"$test_root/old-host-bin/sw_vers" <<'EOF'
#!/bin/bash
printf '%s\n' '25.5'
EOF
chmod 0755 "$test_root/old-host-bin/sw_vers"
assert_fails_with 'requires macOS 26 or newer' env \
  PATH="$test_root/old-host-bin:$PATH" "$native_dir/run-qemu-gpu.sh"
assert_fails_with 'macOS 26 or newer is required' env \
  PATH="$test_root/old-host-bin:$PATH" "$native_dir/build-app.sh"

echo 'macos compatibility tests passed'
