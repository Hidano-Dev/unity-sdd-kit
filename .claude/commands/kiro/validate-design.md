---
description: Interactive technical design quality review and validation (codex-first, Claude subagent fallback)
allowed-tools: Read, Bash, Task
argument-hint: <feature-name>
---

# Technical Design Validation

設計レビューを **codex exec を第一優先**で実行し、Codex が利用不可・実行失敗の場合のみ Claude サブエージェント（validate-design-agent）にフォールバックする。

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

```bash
codex exec --sandbox read-only - <<'CODEX_EOF' 2>&1 | tee /tmp/codex-validate-design-output.log
<codex_prompt>
CODEX_EOF
codex_exit=${PIPESTATUS[0]}
```

> **Note:**
> - prompt は heredoc 経由で stdin に渡す（クォート/エスケープ事故回避）。`-` 引数で stdin から読み取らせる。
> - 設計レビューは読み取り専用のため `--sandbox read-only` で実行する（ファイル変更は許可しない）。
> - Codex は cwd 配下の `AGENTS.md` を自動ロードする。
> - Bash tool の timeout パラメータで 15 分（900 秒）のタイムアウトを設定する。
> - 出力を `tee` でログファイルに保存し、失敗時の理由確認に使う。

`<codex_prompt>` は以下（`$1` は実際の feature 名に置換する）:

```
You are performing a read-only technical design quality review for the feature "$1". Read the following files: .kiro/specs/$1/spec.json, .kiro/specs/$1/requirements.md, .kiro/specs/$1/design.md, all files under .kiro/steering/, and .kiro/settings/rules/design-review.md. Follow the review process in design-review.md: Analysis -> Critical Issues -> Strengths -> GO/NO-GO. Limit critical issues to the 3 most important concerns that significantly impact success (quality assurance, not perfection seeking), give a balanced assessment recognizing strengths, and make all feedback actionable. Do NOT modify any files. Write the report in the language specified in spec.json (field: language; default to English if missing). Structure the report with Markdown headings: (1) Review Summary (2-3 sentences), (2) Critical Issues (max 3, following design-review.md format), (3) Design Strengths (1-2 points), (4) Final Assessment with a clear GO/NO-GO decision and rationale. Output the full report to stdout and complete the session without waiting for user input.
```

## Step 2: 結果判定

- **codex_exit が 0** → codex の出力をそのまま検証レポートとして扱い、Display Result へ進む（GO/NO-GO はレポート内容であり、失敗ではない）。
- **codex_exit が非ゼロ、またはタイムアウト** → ログ末尾から失敗理由（使用制限・エラー等）を一言で記録し、Step 3 のフォールバックへ進む。
  - spec-run と異なり検証はスキップできないため、失敗理由を問わず（使用制限に限らず）フォールバックする。

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
