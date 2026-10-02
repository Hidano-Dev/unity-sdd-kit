#!/usr/bin/env bash
# =============================================================================
# unity-sdd-kit 配布物の同期スクリプト
# -----------------------------------------------------------------------------
# 使い方: sync.sh <kit のチェックアウト> <取り込み側リポジトリのルート>
#
# 取り込み側の SDD Sync ワークフロー (templates/consumer/sdd-sync.yml) と
# install.sh から呼ばれる。同期ロジックはここにだけ置き、ワークフロー本体は
# kit を clone してこのスクリプトを呼ぶだけにする (ロジックを直しても取り込み側の
# ワークフローファイルを書き換えずに済む)。
#
# - kit が所有するパスだけを扱う (OWNED_DIRS / OWNED_FILES / .agents/skills/kiro-*)。
#   所有ディレクトリは kit 側と同じ内容に揃える (kit で削除したファイルは消える)。
#   それ以外のパス (.kiro/specs, .kiro/steering, .kiro/orchestration, 自作 skill、
#   agentic-dev-harness の配布物など) には触れない。
# - AGENTS.md は先頭にマーカーがあるものだけ上書きする (マーカーが無い = 独自ファイル)。
#   旧配布元 agentic-dev-harness のマーカーも管理対象とみなす (移行のため)。
# - ルート CLAUDE.md に IMPORT_LINE が無ければ追記する (ファイルが無ければ作る)。
# - 同期先にシンボリックリンクや submodule があれば何も書き換えずに中止する。
# =============================================================================
set -euo pipefail

KIT="${1:?kit のチェックアウトを指定してください}"
TARGET="${2:?取り込み側リポジトリのルートを指定してください}"
KIT=$(cd "$KIT" && pwd)
TARGET=$(cd "$TARGET" && pwd)

OWNED_DIRS=".claude/commands/kiro .claude/agents/kiro .claude/skills/dev-orchestrator .kiro/settings"
OWNED_FILES=".claude/rules/sdd-workflow.md .claude/rules/unity-sdd.md .codex/agents/spec-reviewer.toml"
SKILLS_DIR=".agents/skills"
SKILL_PREFIX="kiro-"
AGENTS_MD_MARKER="managed-by: unity-sdd-kit"
AGENTS_MD_LEGACY_MARKER="managed-by: agentic-dev-harness"
IMPORT_LINE="@.claude/rules/sdd-workflow.md"

if [ "$KIT" = "$TARGET" ]; then
  echo "::error::kit 自身には同期できません" >&2
  exit 1
fi
if [ ! -f "$KIT/.claude/rules/sdd-workflow.md" ]; then
  echo "::error::$KIT は unity-sdd-kit のチェックアウトではありません" >&2
  exit 1
fi
if ! head -n 1 "$KIT/AGENTS.md" | grep -qF "$AGENTS_MD_MARKER"; then
  echo "::error::配布元の AGENTS.md 先頭にマーカー ($AGENTS_MD_MARKER) がありません" >&2
  exit 1
fi

# ── 事前検査: 同期先にシンボリックリンク / submodule があれば中止 ──────
# リンクがあると cp はリンク先へ書き込み、無関係なファイルを変更しかねない。
# submodule (gitlink) の中に書いても superproject のコミットに乗らない。
kit_skills=""
for d in "$KIT/$SKILLS_DIR/$SKILL_PREFIX"*/; do
  [ -d "$d" ] && kit_skills="$kit_skills $(basename "$d")"
done
check_paths="$OWNED_DIRS $OWNED_FILES AGENTS.md CLAUDE.md"
for s in $kit_skills; do check_paths="$check_paths $SKILLS_DIR/$s"; done
bad=""
for p in $check_paths; do
  # 途中のディレクトリがリンクでも書き込みが外へ出るので、各構成要素を見る
  cur="$TARGET"
  IFS='/' read -r -a parts <<< "$p"
  for part in "${parts[@]}"; do
    cur="$cur/$part"
    if [ -L "$cur" ]; then bad="$bad ${cur#"$TARGET"/}"; break; fi
  done
  if [ -d "$TARGET/$p" ] && [ ! -L "$TARGET/$p" ]; then
    found=$(find "$TARGET/$p" -type l -print)
    [ -n "$found" ] && bad="$bad $found"
  fi
done
if git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  gitlinks=$(git -C "$TARGET" ls-files --stage -- $check_paths | awk '$1 == "160000" { print $4 }')
  [ -n "$gitlinks" ] && bad="$bad $gitlinks"
fi
if [ -n "$bad" ]; then
  echo "::error::同期先にシンボリックリンクまたは submodule があるため中止しました (通常のファイル・ディレクトリにしてから再実行してください):$bad" >&2
  exit 1
fi

# ── 所有ディレクトリ: kit と同じ内容に揃える ──────────────────────
for d in $OWNED_DIRS; do
  rm -rf "${TARGET:?}/$d"
  mkdir -p "$(dirname "$TARGET/$d")"
  cp -R "$KIT/$d" "$TARGET/$d"
done

# ── 所有ファイル ─────────────────────────────────────────
for f in $OWNED_FILES; do
  mkdir -p "$(dirname "$TARGET/$f")"
  cp "$KIT/$f" "$TARGET/$f"
done

# ── Codex 用 skill (.agents/skills/kiro-*) ──────────────────────
# kiro- で始まる skill は kit 所有。kit に無いものは削除し、kit のものは揃える。
# それ以外の skill (unity-cli など) には触れない。
mkdir -p "$TARGET/$SKILLS_DIR"
for existing in "$TARGET/$SKILLS_DIR/$SKILL_PREFIX"*/; do
  [ -d "$existing" ] || continue
  name=$(basename "$existing")
  [ -d "$KIT/$SKILLS_DIR/$name" ] || rm -rf "$existing"
done
for s in $kit_skills; do
  rm -rf "${TARGET:?}/$SKILLS_DIR/$s"
  cp -R "$KIT/$SKILLS_DIR/$s" "$TARGET/$SKILLS_DIR/$s"
done

# ── AGENTS.md (マーカー付き、または未作成のときだけ) ────────────────
if [ ! -f "$TARGET/AGENTS.md" ] \
  || grep -qF "$AGENTS_MD_MARKER" "$TARGET/AGENTS.md" \
  || grep -qF "$AGENTS_MD_LEGACY_MARKER" "$TARGET/AGENTS.md"; then
  cp "$KIT/AGENTS.md" "$TARGET/AGENTS.md"
else
  echo "::notice::AGENTS.md にマーカー ($AGENTS_MD_MARKER) が無いため独自ファイルとみなし、上書きしません"
fi

# ── CLAUDE.md の import 行 ───────────────────────────────────
if [ ! -f "$TARGET/CLAUDE.md" ]; then
  printf '# 開発メモ\n\n## SDD ワークフロー\n\n%s\n' "$IMPORT_LINE" > "$TARGET/CLAUDE.md"
  echo "CLAUDE.md を作成しました"
elif ! tr -d '\r' < "$TARGET/CLAUDE.md" | grep -qxF "$IMPORT_LINE"; then
  [ -n "$(tail -c 1 "$TARGET/CLAUDE.md")" ] && echo >> "$TARGET/CLAUDE.md"
  printf '\n## SDD ワークフロー\n\n%s\n' "$IMPORT_LINE" >> "$TARGET/CLAUDE.md"
  echo "CLAUDE.md に $IMPORT_LINE を追記しました"
fi

echo "unity-sdd-kit の配布物を同期しました: $TARGET"
