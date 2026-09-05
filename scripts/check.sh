#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

for script in scripts/*.sh; do
    /bin/bash -n "$script"
done
/usr/bin/plutil -lint Resources/Info.plist Resources/ZebTrace.entitlements
swift test
"$PROJECT_ROOT/scripts/build.sh"
echo "Checks passed. Audio permissions and real device capture need manual testing."
