---
description: Analyze implementation gap between requirements and existing codebase (codex-first, Claude subagent fallback)
allowed-tools: Read, Bash, Task
argument-hint: <feature-name>
---

# Implementation Gap Validation

Gap 分析を **codex exec を第一優先**で実行し、Codex が利用不可・実行失敗の場合のみ Claude サブエージェント（validate-gap-agent）にフォールバックする。

## Parse Arguments
- Feature name: `$1`

## Validate
Check that requirements have been completed:
- Verify `.kiro/specs/$1/` exists
- Verify `.kiro/specs/$1/requirements.md` exists

If validation fails, inform user to complete requirements phase first.

Codex の存在確認:
- `codex --version` を実行。成功すれば codex-first モード。
- 失敗（コマンド未インストール）した場合は Step 1〜2 をスキップし、最初から Step 3 の Claude サブエージェントで実行する（ユーザーに確認は不要）。

## Step 1: codex exec で実行（codex 利用可の場合のみ）

```bash
codex exec --sandbox read-only - <<'CODEX_EOF' 2>&1 | tee /tmp/codex-validate-gap-output.log
<codex_prompt>
CODEX_EOF
codex_exit=${PIPESTATUS[0]}
```

> **Note:**
> - prompt は heredoc 経由で stdin に渡す（クォート/エスケープ事故回避）。`-` 引数で stdin から読み取らせる。
> - Gap 分析は読み取り専用のため `--sandbox read-only` で実行する（ファイル変更は許可しない）。
> - Codex は cwd 配下の `AGENTS.md` を自動ロードする。
> - Bash tool の timeout パラメータで 15 分（900 秒）のタイムアウトを設定する。
> - 出力を `tee` でログファイルに保存し、失敗時の理由確認に使う。

`<codex_prompt>` は以下（`$1` は実際の feature 名に置換する）:

```
You are performing a read-only implementation gap analysis for the feature "$1". Read the following files: .kiro/specs/$1/spec.json, .kiro/specs/$1/requirements.md, all files under .kiro/steering/, and .kiro/settings/rules/gap-analysis.md. Follow the analysis framework in gap-analysis.md: investigate the existing codebase for reusable patterns, components, and integration points; identify missing capabilities and integration challenges; and evaluate multiple implementation approaches (extend / new / hybrid) with trade-offs. Provide analysis and options, not final implementation decisions, and explicitly flag areas needing further research. Do NOT modify any files. Write the report in the language specified in spec.json (field: language; default to English if missing). Structure the report with Markdown headings: (1) Analysis Summary (3-5 bullets, under 300 words), (2) detailed analysis following the output guidelines in gap-analysis.md, (3) Next Steps for the design phase. Output the full report to stdout and complete the session without waiting for user input.
```

## Step 2: 結果判定

- **codex_exit が 0** → codex の出力をそのまま検証レポートとして扱い、Display Result へ進む。
- **codex_exit が非ゼロ、またはタイムアウト** → ログ末尾から失敗理由（使用制限・エラー等）を一言で記録し、Step 3 のフォールバックへ進む。
  - spec-run と異なり検証はスキップできないため、失敗理由を問わず（使用制限に限らず）フォールバックする。

## Step 3: Claude サブエージェントへフォールバック

Delegate gap analysis to validate-gap-agent:

Use the Task tool to invoke the Subagent with file path patterns:

```
Task(
  subagent_type="validate-gap-agent",
  description="Analyze implementation gap",
  prompt="""
Feature: $1
Spec directory: .kiro/specs/$1/

File patterns to read:
- .kiro/specs/$1/spec.json
- .kiro/specs/$1/requirements.md
- .kiro/steering/*.md
- .kiro/settings/rules/gap-analysis.md
"""
)
```

## Display Result

使用したエンジン（codex / claude-subagent-fallback、フォールバック時はその理由）を明記したうえで、検証レポートの要約を表示し、次のステップを案内する:

### Next Phase: Design Generation

**If Gap Analysis Complete**:
- Review gap analysis insights
- Run `/kiro:spec-design $1` to create technical design document
- Or `/kiro:spec-design $1 -y` to auto-approve requirements and proceed directly

**Note**: Gap analysis is optional but recommended for brownfield projects to inform design decisions.
