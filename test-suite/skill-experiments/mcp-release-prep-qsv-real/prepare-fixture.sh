#!/usr/bin/env bash
set -euo pipefail

revision=9673f2ae77bcb65d6e5fc6573f47aaaad36cfd66
experiment_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture_root="$experiment_dir/fixture"
source_repo="${QSV_SOURCE_REPO:-/home/erchius/development/qsv-sog-fixture}"

if ! git -C "$source_repo" cat-file -e "$revision^{commit}" 2>/dev/null; then
  git -C "$source_repo" fetch origin "$revision"
fi

mkdir -p "$fixture_root/.claude/skills"
git -C "$source_repo" archive "$revision" .claude/skills \
  | tar -x -C "$fixture_root" --strip-components=0

git -C "$source_repo" log --oneline --no-merges --grep='(mcp)' 16.1.0.."$revision" \
  > "$fixture_root/.claude/skills/release-commits.txt"

npm --prefix "$fixture_root/.claude/skills" ci --ignore-scripts

printf 'Prepared qsv MCP fixture at %s from %s\n' "$fixture_root" "$revision"

