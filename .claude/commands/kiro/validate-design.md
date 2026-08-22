---
description: Interactive technical design quality review and validation (codex-first, Claude subagent fallback)
allowed-tools: Read, Bash, Task
argument-hint: <feature-name>
---

# Technical Design Validation

設計レビューを **codex exec を第一優先**で実行し、Codex が利用不可・実行失敗の場合のみ Claude サブエージェント（validate-design-agent）にフォールバックする。
codex 経路では canonical skill（`.agents/skills/kiro-validate-design/SKILL.md`）に従ってレビューする。

## Parse Arguments
- Feature name: `$1`

## Validate
Check that design has been completed:
- Verify `.kiro/specs/$1/` exists
- Verify `.kiro/specs/$1/design.md` exists

If validation fails, inform user to complete design phase first.

Codex の存在確認:
- `codex --version` を実行。成功すれば codex-first モード。
- 失敗（コマンド未インストール）した場合は Step 1〜2 をスキップし、最初から Step 3 の Claude サブエージェントで実行する（ユーザーに確認は不要）。

## Step 1: codex exec で実行（codex 利用可の場合のみ）

以下を **1 回の Bash 呼び出し**で実行する（`codex_exit` はシェルをまたいで持ち越せないため、同一シェル内で `CODEX_EXIT=` マーカーとして出力に残す）:

```bash
umask 077
VAL_TMP=$(mktemp -d)
echo "VAL_TMP=$VAL_TMP"
codex exec --sandbox read-only - <<'CODEX_EOF' 2>&1 | tee "$VAL_TMP/codex-output.log"
<codex_prompt>
CODEX_EOF
codex_exit=${PIPESTATUS[0]}
echo "CODEX_EXIT=$codex_exit"
```

> **Note:**
> - prompt は heredoc 経由で stdin に渡す（クォート/エスケープ事故回避）。`-` 引数で stdin から読み取らせる。
> - 設計レビューは読み取り専用（canonical skill にファイル書き込みは無い）ため `--sandbox read-only` で実行する。
> - Codex は cwd 配下の `AGENTS.md` を自動ロードする。
> - Bash tool の timeout パラメータで 15 分（900 秒）のタイムアウトを設定する。
> - ログは `umask 077` + `mktemp -d`（モード 0700 のプライベートディレクトリ）配下に保存する。codex の出力にはコードベース由来の非公開情報が含まれ得るため、共有マシンの他ユーザーから読める固定の `/tmp` パスには置かない。

`<codex_prompt>` は以下（`$1` は実際の feature 名に置換する）:

```
You are running the canonical design review skill for the feature "$1". Read and follow .agents/skills/kiro-validate-design/SKILL.md (review criteria: .agents/skills/kiro-validate-design/rules/design-review.md): load .kiro/specs/$1/spec.json, .kiro/specs/$1/requirements.md, .kiro/specs/$1/design.md and core steering under .kiro/steering/, then execute the review process Analysis -> Critical Issues (max 3, only those significantly impacting success) -> Strengths -> GO/NO-GO. This is a non-interactive run: instead of engaging in dialogue, include any clarifying questions and proposed alternatives in the report itself. Do NOT modify any files. Write the report in the language specified in spec.json (field: language; default to English if missing). Structure with Markdown headings: (1) Review Summary (2-3 sentences), (2) Critical Issues (max 3, following design-review.md format), (3) Design Strengths (1-2 points), (4) Final Assessment with a clear GO/NO-GO decision and rationale. Output the full report to stdout and complete the session without waiting for user input.
```

## Step 2: 結果判定

判定は Bash tool の終了コードではなく、**出力末尾の `CODEX_EXIT=` マーカー**で行う（`tee` と代入により Bash 呼び出し自体は成功扱いになるため）。

- **`CODEX_EXIT=0`** → codex の出力をそのまま検証レポートとして扱い、Display Result へ進む（GO/NO-GO はレポート内容であり、失敗ではない）。
- **`CODEX_EXIT=` が非ゼロ、マーカー欠落、またはタイムアウト** → ログ末尾から失敗理由（使用制限・認証エラー等）を一言で記録し、Step 3 のフォールバックへ進む。
  - spec-run と異なり検証はスキップできないため、失敗理由を問わず（使用制限に限らず）フォールバックする。
- 判定と失敗理由の取得が済んだら、`VAL_TMP=` マーカーの実パスを使って `rm -rf "$VAL_TMP"` でログディレクトリを削除する（タイムアウト時も出力済みの `VAL_TMP=` があれば削除する）。

## Step 3: Claude サブエージェントへフォールバック

Delegate design validation to validate-design-agent:

Use the Task tool to invoke the Subagent with file path patterns:

```
Task(
  subagent_type="validate-design-agent",
  description="Interactive design review",
  prompt="""
Feature: $1
Spec directory: .kiro/specs/$1/

File patterns to read:
- .kiro/specs/$1/spec.json
- .kiro/specs/$1/requirements.md
- .kiro/specs/$1/design.md
- .kiro/steering/*.md
- .kiro/settings/rules/design-review.md
"""
)
```

## Display Result

使用したエンジン（codex / claude-subagent-fallback、フォールバック時はその理由）を明記したうえで、検証レポートの要約を表示し、次のステップを案内する:

### Next Phase: Task Generation

**If Design Passes Validation (GO Decision)**:
- Review feedback and apply changes if needed
- Run `/kiro:spec-tasks $1` to generate implementation tasks
- Or `/kiro:spec-tasks $1 -y` to auto-approve and proceed directly

**If Design Needs Revision (NO-GO Decision)**:
- Address critical issues identified
- Re-run `/kiro:spec-design $1` with improvements
- Re-validate with `/kiro:validate-design $1`

**Note**: Design validation is recommended but optional. Quality review helps catch issues early.
