#!/usr/bin/env bash
# =============================================================================
# scripts/sync.sh / scripts/install.sh の回帰テスト
# 使い方: bash tests/sync-test.sh   (kit のルートで実行。CI では Linux で回す)
# =============================================================================
set -euo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILED=0

# check <名前> <コマンド...> : コマンドが成功すれば ok、失敗すれば FAIL
check() {
  local name="$1"
  shift
  if "$@"; then echo "ok   - $name"; else echo "FAIL - $name"; FAILED=1; fi
}
new_target() {
  local t="$WORK/$1"
  mkdir -p "$t"
  git -C "$t" init -q
  git -C "$t" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  echo "$t"
}
commit_all() { git -C "$1" add -A && git -C "$1" -c user.name=t -c user.email=t@t commit -qm snapshot; }
has_marker() { head -n 1 "$1" | grep -qF "managed-by: unity-sdd-kit"; }
is_empty_dir() { [ -z "$(find "$1" -mindepth 1 -print -quit)" ]; }
sync_fails() { ! bash "$KIT/scripts/sync.sh" "$KIT" "$1" >/dev/null 2>&1; }

# 1. 新規導入: 配布物・同期ワークフロー・CLAUDE.md の import 行
T=$(new_target fresh)
mkdir -p "$T/.agents/skills/unity-cli" && echo keep > "$T/.agents/skills/unity-cli/SKILL.md"
printf '# memo\n' > "$T/CLAUDE.md"
bash "$KIT/scripts/install.sh" "$T" >/dev/null
check "sdd-workflow.md synced" test -f "$T/.claude/rules/sdd-workflow.md"
check "unity-sdd.md synced" test -f "$T/.claude/rules/unity-sdd.md"
check "kiro skills synced" test -d "$T/.agents/skills/kiro-impl"
check "foreign skill kept" test -f "$T/.agents/skills/unity-cli/SKILL.md"
check "sync workflow placed" test -f "$T/.github/workflows/sdd-sync.yml"
check "import line appended once" test "$(grep -cxF '@.claude/rules/sdd-workflow.md' "$T/CLAUDE.md")" = 1
check "AGENTS.md placed" has_marker "$T/AGENTS.md"

# 2. 冪等性
commit_all "$T"
bash "$KIT/scripts/install.sh" "$T" >/dev/null
check "idempotent" test -z "$(git -C "$T" status --porcelain)"

# 3. AGENTS.md: 旧マーカーは上書き、マーカー無しは維持
printf '<!-- managed-by: agentic-dev-harness -->\nold\n' > "$T/AGENTS.md"
bash "$KIT/scripts/sync.sh" "$KIT" "$T" >/dev/null
check "legacy-marker AGENTS.md replaced" has_marker "$T/AGENTS.md"
printf 'my own\n' > "$T/AGENTS.md"
bash "$KIT/scripts/sync.sh" "$KIT" "$T" >/dev/null
check "custom AGENTS.md kept" test "$(cat "$T/AGENTS.md")" = "my own"

# 4. 所有パスの古いファイルは消え、所有外 (.kiro/steering など) は残る
mkdir -p "$T/.agents/skills/kiro-obsolete" "$T/.kiro/steering" "$T/.kiro/orchestration"
echo x > "$T/.agents/skills/kiro-obsolete/SKILL.md"
echo x > "$T/.claude/commands/kiro/obsolete.md"
echo keep > "$T/.kiro/steering/product.md"
echo '{}' > "$T/.kiro/orchestration/config.json"
bash "$KIT/scripts/sync.sh" "$KIT" "$T" >/dev/null
check "stale kiro skill removed" test ! -e "$T/.agents/skills/kiro-obsolete"
check "stale command removed" test ! -e "$T/.claude/commands/kiro/obsolete.md"
check ".kiro/steering kept" test -f "$T/.kiro/steering/product.md"
check ".kiro/orchestration kept" test -f "$T/.kiro/orchestration/config.json"

# 5. シンボリックリンクがあれば何も書き換えずに中止
T=$(new_target symlink)
mkdir -p "$WORK/outside" "$T/.kiro"
ln -s "$WORK/outside" "$T/.kiro/settings"
check "symlinked owned dir rejected" sync_fails "$T"
check "nothing written through symlink" is_empty_dir "$WORK/outside"
check "nothing written before abort" test ! -e "$T/.claude"

T=$(new_target symlink-parent)
mkdir -p "$WORK/outside2"
ln -s "$WORK/outside2" "$T/.claude"
check "symlinked parent rejected" sync_fails "$T"
check "nothing written through parent symlink" is_empty_dir "$WORK/outside2"

exit $FAILED
