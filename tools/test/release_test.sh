#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf -- "$temp"' EXIT
cd "$temp"
git init -q
git config user.name 'Release Test'
git config user.email 'release-test@example.test'
mkdir -p tools scripts
cp "$root/tools/release.sh" tools/
printf '1.0.0\n' > VERSION
printf '# Что нового\n\n## v1.0.0: initial\n\n- First release\n' > CHANGELOG.md
for file in scripts/3x-ui.sh scripts/hysteria2.sh scripts/kit.sh; do
  printf '#!/usr/bin/env bash\nKIT_VERSION="1.0.0"\n' > "$file"
  chmod +x "$file"
done
touch scripts/kit-sub.py
git add .
git commit -qm 'Initial release'
git tag v1.0.0
printf 'change\n' > example
git add example
git commit -qm 'Add feature'

bash tools/release.sh prepare v1.0.1
[[ $(cat VERSION) == 1.0.1 ]]
[[ -x scripts/3x-ui.sh ]]
for file in scripts/*.sh; do grep -qx 'KIT_VERSION="1.0.1"' "$file"; done
bash tools/release.sh notes v1.0.1 | grep -E '^-[[:space:]]Add feature \([0-9a-f]+\)$'
[[ $(bash tools/release.sh notes 1.0.0) == '- First release' ]]
if bash tools/release.sh prepare 1.0.2; then exit 1; fi
if bash tools/release.sh notes 1.0; then exit 1; fi

ssh-keygen -q -t ed25519 -N '' -f "$temp/test-key"
printf '\nKIT_SIGNERS=(\n  "%s"\n)\n' "$(cat "$temp/test-key.pub")" >> scripts/kit.sh
{
  printf '# 3X-UI KIT 1.0.1\n'
  sha256sum scripts/3x-ui.sh scripts/hysteria2.sh scripts/kit.sh scripts/kit-sub.py VERSION
} > SHA256SUMS
ssh-keygen -Y sign -f "$temp/test-key" -n 3x-ui-kit-release SHA256SUMS
bash tools/release.sh verify
printf '# change\n' >> scripts/kit-sub.py
if bash tools/release.sh verify; then exit 1; fi
