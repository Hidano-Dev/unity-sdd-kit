#!/usr/bin/env bash
# =============================================================================
# unity-sdd-kit 導入スクリプト
# -----------------------------------------------------------------------------
# 使い方 (取り込み側リポジトリのルートで実行):
#   curl -fsSL https://raw.githubusercontent.com/Hidano-Dev/unity-sdd-kit/main/scripts/install.sh | bash
# または kit をローカルに clone 済みなら:
#   bash <kit>/scripts/install.sh [取り込み側リポジトリのルート (既定: カレント)]
#
# 行うこと (何度実行しても同じ結果になる):
#   1. SDD 配布物を同期 (scripts/sync.sh。CLAUDE.md への import 行追加を含む)
#   2. 同期ワークフロー .github/workflows/sdd-sync.yml を配置 (既にあれば触らない)
# コミットはしないので、差分を確認してから自分でコミット・push する。
# =============================================================================
set -euo pipefail

KIT_REPO="${KIT_REPO:-Hidano-Dev/unity-sdd-kit}"
KIT_REF="${KIT_REF:-main}"
TARGET=$(cd "${1:-.}" && pwd)

if ! git -C "$TARGET" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "error: $TARGET は git リポジトリではありません" >&2
  exit 1
fi
if [ "$(cd "$(git -C "$TARGET" rev-parse --show-toplevel)" && pwd)" != "$TARGET" ]; then
  echo "error: リポジトリのルートで実行してください ($TARGET はルートではありません)" >&2
  exit 1
fi

# スクリプトの隣に sync.sh があればそのチェックアウトを使い、無ければ (curl | bash) clone する
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi
CLEANUP=""
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/sync.sh" ]; then
  KIT=$(cd "$SCRIPT_DIR/.." && pwd)
else
  KIT=$(mktemp -d)
  CLEANUP="$KIT"
  git clone -q --depth 1 --branch "$KIT_REF" --single-branch "https://github.com/${KIT_REPO}.git" "$KIT"
fi
trap '[ -n "$CLEANUP" ] && rm -rf "$CLEANUP"' EXIT

WF_REL=".github/workflows/sdd-sync.yml"
WF="$TARGET/$WF_REL"

# 同期ワークフローの配置先 (途中のディレクトリを含む) がリンクだとリポジトリ外へ書き込むので、
# 何かを書き換える前に検査して中止する
cur="$TARGET"
IFS='/' read -r -a parts <<< "$WF_REL"
for part in "${parts[@]}"; do
  cur="$cur/$part"
  if [ -L "$cur" ]; then
    echo "error: ${cur#"$TARGET"/} がシンボリックリンクのため中止しました (通常のファイル・ディレクトリにしてから再実行してください)" >&2
    exit 1
  fi
done

bash "$KIT/scripts/sync.sh" "$KIT" "$TARGET"

if [ -e "$WF" ]; then
  echo "既存の .github/workflows/sdd-sync.yml を維持しました"
else
  mkdir -p "$(dirname "$WF")"
  cp "$KIT/templates/consumer/sdd-sync.yml" "$WF"
  echo ".github/workflows/sdd-sync.yml を配置しました"
fi

# 旧経路 (unity-sdd-template 生成先の orchestration-sync.yml / agentic-dev-harness の
# harness-sync.yml) は SDD の取り込み元としては使われなくなった。linear-worker など
# harness 側の配布物の同期に使っている場合があるため、ここでは消さずに知らせるだけにする
for old in orchestration-sync.yml harness-sync.yml; do
  if [ -f "$TARGET/.github/workflows/$old" ]; then
    echo "notice: .github/workflows/$old があります。SDD は今後 sdd-sync.yml で同期されます。$old の扱いは unity-sdd-kit の README「移行」を参照してください"
  fi
done

echo
echo "完了しました。git status で差分を確認してからコミットしてください。"
