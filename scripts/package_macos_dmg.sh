#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Preserve the old package_macos_dmg.sh behavior: package and sign only unless
# the caller explicitly enables notarization.
export SKIP_NOTARY="${SKIP_NOTARY:-1}"
exec "$script_dir/package_macos.sh" "$@"
