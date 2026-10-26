#!/bin/bash
#
# Checks that the export policy a built try-omarchy package ships still
# matches this tree: every Try file the policy cites, with its digest. A Try
# change to one of them needs a new policy revision in omarchy-migration.
#
#   guest/tests/migration-policy.sh PACKAGE

set -euo pipefail

fail() {
  echo "migration-policy: $*" >&2
  exit 1
}

package=${1:?usage: migration-policy.sh PACKAGE}
repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/migration-policy.XXXXXX")
trap 'rm -rf "$work"' EXIT

tar -xf "$package" -C "$work" usr/lib/try-omarchy/migration/omarchy-migration
migration="$work/usr/lib/try-omarchy/migration/omarchy-migration"
policies=("$migration"/lib/omarchy_migration/policies/*.json)
((${#policies[@]} == 1)) && [[ -f ${policies[0]} ]] || fail "the package ships ${#policies[@]} policies, not one"
bash "$migration/bin/omarchy-migration" evidence "${policies[0]}" "$repo_dir" >"$work/evidence.json" ||
  fail "the policy's evidence changed; cut a new policy revision in omarchy-migration and vendor it:
$(cat "$work/evidence.json")"
echo "migration-policy: $(basename "${policies[0]}") matches this tree"
