---
description: Validate implementation against requirements, design, and tasks (codex-first, Claude subagent fallback)
allowed-tools: Read, Bash, Task
argument-hint: [feature-name] [task-numbers]
---

# Implementation Validation

実装検証を **codex exec を第一優先**で実行し、Codex が利用不可・実行失敗の場合のみ Claude サブエージェント（validate-impl-agent）にフォールバックする。

## Parse Arguments
- Feature name: `$1` (optional)
- Task numbers: `$2` (optional)

## Auto-Detection Logic

**Perform detection before invoking any engine (codex / Subagent)**:

**If no arguments** (`$1` empty):
- Parse conversation history for `/kiro:spec-impl <feature> [tasks]` patterns
- OR scan `.kiro/specs/*/tasks.md` for `[x]` checkboxes
- Pass detected features and tasks to the engine

**If feature only** (`$1` present, `$2` empty):
- Read `.kiro/specs/$1/tasks.md` and find all `[x]` checkboxes
- Pass feature and detected tasks to the engine

**If both provided** (`$1` and `$2` present):
- Pass directly to the engine without detection

Codex の存在確認:
- `codex --version` を実行。成功すれば codex-first モード。
- 失敗（コマンド未インストール）した場合は Step 1〜2 をスキップし、最初から Step 3 の Claude サブエージェントで実行する（ユーザーに確認は不要）。

## Step 1: codex exec で実行（codex 利用可の場合のみ）

```bash
codex exec --dangerously-bypass-approvals-and-sandbox - <<'CODEX_EOF' 2>&1 | tee /tmp/codex-validate-impl-output.log
<codex_prompt>
CODEX_EOF
codex_exit=${PIPESTATUS[0]}
```

> **Note:**
> - prompt は heredoc 経由で stdin に渡す（クォート/エスケープ事故回避）。`-` 引数で stdin から読み取らせる。
> - `--dangerously-bypass-approvals-and-sandbox` はテストランナー（UnityTestRunner 等の workspace 外プロセス）の起動を許可するため。ファイルを変更しないことはプロンプト側で明示的に禁止する。
> - Codex は cwd 配下の `AGENTS.md` を自動ロードする。
> - Bash tool の timeout パラメータで 30 分（1800 秒）のタイムアウトを設定する（テストスイート実行を含むため）。
> - 出力を `tee` でログファイルに保存し、失敗時の理由確認に使う。

`<codex_prompt>` は以下（`{feature}` / `{tasks}` は Auto-Detection の結果に置換する）:

```
You are performing a validation-only review of the implementation for the feature "{feature}", target tasks: {tasks}. This is validation, NOT implementation: do NOT modify, create, or delete any files, and do NOT commit — the only permitted side effects are running test commands. Read the following files: .kiro/specs/{feature}/spec.json, .kiro/specs/{feature}/requirements.md, .kiro/specs/{feature}/design.md, .kiro/specs/{feature}/tasks.md, and all files under .kiro/steering/. For each target task verify: (1) Task completion — checkbox is [x] in tasks.md; (2) Test coverage — tests exist for the task's functionality and pass (run the project's test command, e.g. UnityTestRunner or the runner described in steering/AGENTS.md); (3) Requirements traceability — the related EARS requirements are traceable to code; (4) Design alignment — key interfaces, components, and file structure match design.md; (5) Regression — run the full test suite if available and confirm no existing tests break. Write the report in the language specified in spec.json (field: language; default to English if missing). Structure the report with Markdown headings and tables: (1) Detected Target, (2) Validation Summary (pass/fail counts), (3) Issues with severity (Critical/Warning) and location, (4) Coverage Report, (5) a clear GO/NO-GO decision with rationale. Keep the summary under 400 words. Output the full report to stdout and complete the session without waiting for user input.
```

## Step 2: 結果判定

- **codex_exit が 0** → codex の出力をそのまま検証レポートとして扱い、Display Result へ進む（NO-GO はレポート内容であり、失敗ではない）。
- **codex_exit が非ゼロ、またはタイムアウト** → ログ末尾から失敗理由（使用制限・エラー等）を一言で記録し、Step 3 のフォールバックへ進む。
  - spec-run と異なり検証はスキップできないため、失敗理由を問わず（使用制限に限らず）フォールバックする。
- codex 実行後に `git status` で作業ツリーが汚れていないことを確認する。想定外の変更があれば内容を報告し、ユーザーの指示なく破棄しない。

## Step 3: Claude サブエージェントへフォールバック

Delegate validation to validate-impl-agent:

Use the Task tool to invoke the Subagent with file path patterns:

```
Task(
  subagent_type="validate-impl-agent",
  description="Validate implementation",
  prompt="""
Feature: {$1 or auto-detected}
Target tasks: {$2 or auto-detected}
Mode: {auto-detect, feature-all, or explicit}

File patterns to read:
- .kiro/specs/{feature}/*.{json,md}
- .kiro/steering/*.md

Validation scope: {based on detection results}
"""
)
```

## Display Result

使用したエンジン（codex / claude-subagent-fallback、フォールバック時はその理由）を明記したうえで、検証レポートの要約を表示し、次のステップを案内する:

### Next Steps Guidance

**If GO Decision**:
- Implementation validated and ready
- Proceed to deployment or next feature

**If NO-GO Decision**:
- Address critical issues listed
- Re-run `/kiro:spec-impl <feature> [tasks]` for fixes
- Re-validate with `/kiro:validate-impl [feature] [tasks]`

**Note**: Validation is recommended after implementation to ensure spec alignment and quality.
