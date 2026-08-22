---
description: Validate implementation against requirements, design, and tasks (codex-first, Claude subagent fallback)
allowed-tools: Read, Bash, Task
argument-hint: [feature-name] [task-numbers]
---

# Implementation Validation

実装検証を **codex exec を第一優先**で実行し、Codex が利用不可・実行失敗の場合のみ Claude サブエージェント（validate-impl-agent）にフォールバックする。
codex 経路では canonical skill（`.agents/skills/kiro-validate-impl/SKILL.md`）の integration validation（full test suite / smoke boot / boundary audit / GO・NO-GO・MANUAL_VERIFY_REQUIRED 判定）に従う。

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

**複数 feature が検出された場合**: codex プロンプトは単一 feature 前提のため、**feature ごとに Step 1〜2 を個別に実行**し、レポートも feature 単位で扱う（パスを結合して 1 回で渡さない）。フォールバック（Step 3）の validate-impl-agent は複数 feature の一括処理に対応しているため、まとめて渡してよい。

Codex の存在確認:
- `codex --version` を実行。成功すれば codex-first モード。
- 失敗（コマンド未インストール）した場合は Step 1〜2 をスキップし、最初から Step 3 の Claude サブエージェントで実行する（ユーザーに確認は不要）。

## Step 1: codex exec で実行（codex 利用可の場合のみ）

以下を **1 回の Bash 呼び出し**で実行する（`codex_exit` はシェルをまたいで持ち越せないため、同一シェル内で `CODEX_EXIT=` マーカーとして出力に残す）。sandbox bypass の確認として、実行前後の作業ツリー状態を記録して比較する:

```bash
git status --porcelain > /tmp/validate-impl-tree-before.txt
codex exec --dangerously-bypass-approvals-and-sandbox - <<'CODEX_EOF' 2>&1 | tee /tmp/codex-validate-impl-output.log
<codex_prompt>
CODEX_EOF
codex_exit=${PIPESTATUS[0]}
git status --porcelain > /tmp/validate-impl-tree-after.txt
echo "CODEX_EXIT=$codex_exit"
echo "TREE_DIFF_START"
diff /tmp/validate-impl-tree-before.txt /tmp/validate-impl-tree-after.txt
echo "TREE_DIFF_END"
```

> **Note:**
> - prompt は heredoc 経由で stdin に渡す（クォート/エスケープ事故回避）。`-` 引数で stdin から読み取らせる。
> - `--dangerously-bypass-approvals-and-sandbox` はテストランナー（UnityTestRunner 等の workspace 外プロセス）や build/smoke コマンドの起動を許可するため。ファイルを変更しないことはプロンプト側で明示的に禁止する。
> - 作業ツリーは実行**前後の差分**で監査する。`/kiro:spec-impl` 直後など実行前から dirty なケースがあるため、実行後の `git status` 単体では判定しない。
> - Codex は cwd 配下の `AGENTS.md` を自動ロードする。
> - Bash tool の timeout パラメータで 30 分（1800 秒）のタイムアウトを設定する（テストスイート・smoke 実行を含むため）。
> - 出力を `tee` でログファイルに保存し、失敗時の理由確認に使う。

`<codex_prompt>` は以下（`{feature}` / `{tasks}` は Auto-Detection の結果に置換する。feature ごとに 1 回実行）:

```
You are running the canonical integration validation skill for the feature "{feature}", target tasks: {tasks}. Read and follow .agents/skills/kiro-validate-impl/SKILL.md end-to-end: load the spec documents under .kiro/specs/{feature}/ (spec.json, requirements.md, design.md, tasks.md) and core steering under .kiro/steering/; discover the repository's canonical TEST_COMMANDS / BUILD_COMMANDS / SMOKE_COMMANDS from project scripts, task runners, CI configs, and README; run the mechanical checks (full test suite, TBD/TODO/FIXME grep, hardcoded-secrets grep, runtime smoke boot) and the judgment checks (cross-task integration, requirements coverage gaps, design end-to-end alignment, boundary audit, blocked tasks). Produce the skill's "Validation Report" format ending with DECISION: GO | NO-GO | MANUAL_VERIFY_REQUIRED. If a canonical test or smoke command cannot be identified or executed in this environment, the decision MUST be MANUAL_VERIFY_REQUIRED, never GO. This is validation, NOT implementation: the only permitted side effects are running the discovered test/build/smoke commands; do NOT modify, create, or delete any files, and do NOT commit. Write the report in the language specified in spec.json (field: language; default to English if missing). Output the full report to stdout and complete the session without waiting for user input.
```

## Step 2: 結果判定

判定は Bash tool の終了コードではなく、**出力末尾の `CODEX_EXIT=` マーカー**で行う（`tee` と代入により Bash 呼び出し自体は成功扱いになるため）。

- **`CODEX_EXIT=0`** → codex の出力をそのまま検証レポートとして扱い、Display Result へ進む（NO-GO / MANUAL_VERIFY_REQUIRED はレポート内容であり、実行失敗ではない）。
- **`CODEX_EXIT=` が非ゼロ、マーカー欠落、またはタイムアウト** → ログ末尾から失敗理由（使用制限・認証エラー等）を一言で記録し、Step 3 のフォールバックへ進む。
  - spec-run と異なり検証はスキップできないため、失敗理由を問わず（使用制限に限らず）フォールバックする。
- **作業ツリー監査**: `TREE_DIFF_START`〜`TREE_DIFF_END` が空でない場合（= codex 実行によって新たに変更が生じた場合）は、その内容を「検証中の想定外の変更」として報告する。ユーザーの指示なく破棄・コミットしない。実行前から存在した dirty（before に含まれる分）は想定外扱いにしない。

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

使用したエンジン（codex / claude-subagent-fallback、フォールバック時はその理由）と作業ツリー監査の結果を明記したうえで、検証レポートの要約を表示し、次のステップを案内する:

### Next Steps Guidance

**If GO Decision**:
- Implementation validated and ready
- Proceed to deployment or next feature

**If NO-GO Decision**:
- Address critical issues listed
- Re-run `/kiro:spec-impl <feature> [tasks]` for fixes
- Re-validate with `/kiro:validate-impl [feature] [tasks]`

**If MANUAL_VERIFY_REQUIRED**:
- Do not treat the feature as complete
- Report the exact missing validation step or environment prerequisite for manual verification

**Note**: Validation is recommended after implementation to ensure spec alignment and quality.
