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

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILED=1; }
new_target() {
  local t="$WORK/$1"
  mkdir -p "$t"
  git -C "$t" init -q
  git -C "$t" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  echo "$t"
}
commit_all() { git -C "$1" add -A && git -C "$1" -c user.name=t -c user.email=t@t commit -qm snapshot; }

# 1. 新規導入: 配布物・同期ワークフロー・CLAUDE.md の import 行
T=$(new_target fresh)
mkdir -p "$T/.agents/skills/unity-cli" && echo keep > "$T/.agents/skills/unity-cli/SKILL.md"
printf '# memo\n' > "$T/CLAUDE.md"
bash "$KIT/scripts/install.sh" "$T" >/dev/null
[ -f "$T/.claude/rules/sdd-workflow.md" ] && [ -f "$T/.claude/rules/unity-sdd.md" ] && pass "rules synced" || fail "rules synced"
[ -d "$T/.agents/skills/kiro-impl" ] && pass "kiro skills synced" || fail "kiro skills synced"
[ -f "$T/.agents/skills/unity-cli/SKILL.md" ] && pass "foreign skill kept" || fail "foreign skill kept"
[ -f "$T/.github/workflows/sdd-sync.yml" ] && pass "sync workflow placed" || fail "sync workflow placed"
[ "$(grep -cxF '@.claude/rules/sdd-workflow.md' "$T/CLAUDE.md")" = 1 ] && pass "import line appended once" || fail "import line appended once"
head -n 1 "$T/AGENTS.md" | grep -qF "managed-by: unity-sdd-kit" && pass "AGENTS.md placed" || fail "AGENTS.md placed"

# 2. 冪等性
commit_all "$T"
bash "$KIT/scripts/install.sh" "$T" >/dev/null
[ -z "$(git -C "$T" status --porcelain)" ] && pass "idempotent" || fail "idempotent"

# 3. AGENTS.md: 旧マーカーは上書き、マーカー無しは維持
printf '<!-- managed-by: agentic-dev-harness -->\nold\n' > "$T/AGENTS.md"
bash "$KIT/scripts/sync.sh" "$KIT" "$T" >/dev/null
head -n 1 "$T/AGENTS.md" | grep -qF "managed-by: unity-sdd-kit" && pass "legacy-marker AGENTS.md replaced" || fail "legacy-marker AGENTS.md replaced"
printf 'my own\n' > "$T/AGENTS.md"
bash "$KIT/scripts/sync.sh" "$KIT" "$T" >/dev/null
[ "$(cat "$T/AGENTS.md")" = "my own" ] && pass "custom AGENTS.md kept" || fail "custom AGENTS.md kept"

# 4. 所有パスの古いファイルは消え、所有外 (.kiro/steering など) は残る
mkdir -p "$T/.agents/skills/kiro-obsolete" "$T/.kiro/steering" "$T/.kiro/orchestration"
echo x > "$T/.agents/skills/kiro-obsolete/SKILL.md"
echo x > "$T/.claude/commands/kiro/obsolete.md"
echo keep > "$T/.kiro/steering/product.md"
echo '{}' > "$T/.kiro/orchestration/config.json"
bash "$KIT/scripts/sync.sh" "$KIT" "$T" >/dev/null
[ ! -e "$T/.agents/skills/kiro-obsolete" ] && pass "stale kiro skill removed" || fail "stale kiro skill removed"
[ ! -e "$T/.claude/commands/kiro/obsolete.md" ] && pass "stale command removed" || fail "stale command removed"
[ -f "$T/.kiro/steering/product.md" ] && [ -f "$T/.kiro/orchestration/config.json" ] && pass "non-owned .kiro paths kept" || fail "non-owned .kiro paths kept"

# 5. シンボリックリンクがあれば何も書き換えずに中止
T=$(new_target symlink)
mkdir -p "$WORK/outside" "$T/.kiro"
ln -s "$WORK/outside" "$T/.kiro/settings"
if bash "$KIT/scripts/sync.sh" "$KIT" "$T" >/dev/null 2>&1; then
  fail "symlink target rejected"
else
  [ -z "$(ls -A "$WORK/outside")" ] && [ ! -e "$T/.claude" ] && pass "symlink target rejected" || fail "symlink target rejected (partially written)"
fi
T=$(new_target symlink-parent)
mkdir -p "$WORK/outside2"
ln -s "$WORK/outside2" "$T/.claude"
if bash "$KIT/scripts/sync.sh" "$KIT" "$T" >/dev/null 2>&1; then
  fail "symlinked parent rejected"
else
  [ -z "$(ls -A "$WORK/outside2")" ] && pass "symlinked parent rejected" || fail "symlinked parent rejected (wrote outside)"
fi

exit $FAILED
