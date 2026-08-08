---
description: Run all pending spec tasks sequentially via codex exec, with automatic fallback to claude -p on Codex usage-limit, then run validate-impl (unattended batch execution — starts immediately without confirmation)
allowed-tools: Read, Bash, Glob, Grep, SlashCommand
argument-hint: <feature-name>
---

# Spec Task Batch Runner

各タスクを **codex exec を第一優先**で実行し、Codex の使用制限（rate / usage / quota）を踏んだ場合のみ **そのタスクだけ `claude -p` にフォールバック**して再実行する。次のタスクではまた codex から試す（使用制限は時間で回復するため）。

## Parse Arguments
- Feature name: `$1`

## Validate
Check that tasks have been generated:
- Verify `.kiro/specs/$1/` exists
- Verify `.kiro/specs/$1/tasks.md` exists

If validation fails, inform user to complete tasks generation first (`/kiro:spec-tasks $1`).

Codex の存在確認:
- `codex --version` を実行。成功すれば codex-first モード。
- 失敗（コマンド未インストール）した場合は警告を出し、最初から `claude -p` のみで実行するモードに自動降格する（ユーザーに確認は不要）。

## Extract Tasks

Read `.kiro/specs/$1/tasks.md` and extract all unchecked task lines matching the pattern `- [ ] <number>` or `- [ ]* <number>`.

For each task, extract:
- Task ID (e.g., "1.1", "2", "4.3")
- Task title (the text after the ID)

Format each as: `<id> <title>` (one per line).

Skip container tasks that have subtasks — only include leaf-level (actionable) tasks.

## Announce and Start Immediately

**Do NOT ask the user for confirmation. Do NOT wait for any input.** This command is designed for unattended (walk-away / overnight) execution — the act of invoking it IS the confirmation.

Before starting, display the execution plan in one message (informational only):
- Feature name
- Number of tasks
- Task list (ID + title)
- Approach: per-task に codex exec → 使用制限検知時のみ claude -p へフォールバック（タスクごとにリセット）。各実行 30 分タイムアウト
- Codex 利用可否（`codex --version` の結果）

Then proceed IMMEDIATELY to task execution in the same turn. The only case where you stop before execution is a hard validation failure (missing spec directory / tasks.md, or zero unchecked tasks).

## Execute Tasks

各タスクについて以下の流れで実行する:

### Step 1: codex exec を試行（codex 利用可の場合のみ）

```bash
codex exec --dangerously-bypass-approvals-and-sandbox - <<'CODEX_EOF' 2>&1 | tee /tmp/codex-task-output.log
<codex_prompt>
CODEX_EOF
codex_exit=${PIPESTATUS[0]}
```

> **Note:**
> - prompt は heredoc 経由で stdin に渡す（クォート/エスケープ事故回避）。`-` 引数で stdin から読み取らせる。
> - `--dangerously-bypass-approvals-and-sandbox` は Unity.exe や git のような workspace 外プロセス起動を許可するため。
> - Codex は cwd 配下の `AGENTS.md` を自動ロードする。
> - 出力を `tee` でログファイルに保存し、後続の使用制限判定で grep する。

`<codex_prompt>` は以下:

```
Execute only this single task (<task_id> <task_title>) according to the instructions in AGENTS.md (auto-loaded by Codex) and the spec documents in .kiro/specs/$1/ (requirements.md, design.md, tasks.md). Before starting, output the task name (<task_id> <task_title>). After completing the task, run UnityTestRunner to verify the result. If any file changes exist, run git add -A and then commit. The commit title must be the task name "<task_id> <task_title>" as-is. The commit body must contain a brief summary of what was done (files created/modified, key changes). Use a multi-line commit message with git commit -m "title" -m "body". Finally, output only OK or FAIL. tasks.txt is a user-managed file and must not be modified. After outputting OK or FAIL, complete the session without waiting for user input.
```

### Step 2: 結果判定

判定の優先順位:

1. **codex 出力末尾に `OK`** → タスク成功（OK として記録、次のタスクへ）
2. **codex 出力末尾に `FAIL`** → タスク失敗（FAIL として記録、自動的に次のタスクへ）
3. **codex_exit が非ゼロ かつ ログに使用制限シグネチャあり** → 使用制限ヒット → Step 3 へフォールバック
4. **codex_exit が非ゼロ かつ シグネチャ無し** → 通常の実行失敗（FAIL として記録、自動的に次のタスクへ）
5. **タイムアウト（30 分）** → TIMEOUT として記録、自動的に次のタスクへ

使用制限シグネチャの検出（case-insensitive）:

```bash
grep -iE 'rate.?limit|usage.?limit|quota|\b429\b|too many requests|exceeded your|try again later' /tmp/codex-task-output.log
```

このパターンに該当しても誤検知の可能性はあるため、**判定は必ず「exit code 非ゼロ AND grep ヒット」の AND 条件**で行う。OK/FAIL が明示出力されているケースが優先。

### Step 3: claude -p フォールバック（使用制限検知時のみ）

```bash
unset CLAUDECODE && echo "" | claude -p "<claude_prompt>" --max-turns 60 --enable-auto-mode --verbose
```

> **Note:** `unset CLAUDECODE` は親セッション（このスクリプトを呼んでいる claude）からのネスト起動を許可するため。

`<claude_prompt>` は以下（codex_prompt とほぼ同じだが AGENTS.md → CLAUDE.md）:

```
Execute only this single task (<task_id> <task_title>) according to the instructions in CLAUDE.md and the spec documents in .kiro/specs/$1/ (requirements.md, design.md, tasks.md). Before starting, output the task name (<task_id> <task_title>). After completing the task, run UnityTestRunner to verify the result. If any file changes exist, run git add -A and then commit. The commit title must be the task name "<task_id> <task_title>" as-is. The commit body must contain a brief summary of what was done (files created/modified, key changes). Use a multi-line commit message with git commit -m "title" -m "body". Finally, output only OK or FAIL. tasks.txt is a user-managed file and must not be modified. After outputting OK or FAIL, complete the session without waiting for user input.
```

フォールバック後の結果判定:
- 出力末尾の `OK` / `FAIL` で判定。
- exit code 非ゼロ → FAIL 扱い。
- タイムアウト → TIMEOUT 扱い。
- claude 側でも使用制限を踏んだ場合は FAIL として記録し、自動的に次のタスクへ進む（さらなるフォールバック先は無い。連続失敗ガードに委ねる）。

### Execution Rules
- Run each task sequentially (not in parallel)
- 各実行（codex / claude いずれも）に 30 分タイムアウト（1800 秒）を Bash tool の timeout パラメータで設定
- フォールバック発動時は **そのタスクのみ** claude -p に切り替える。次のタスクではまた codex から試行する（永続切替はしない）
- After each task completes, report which engine was used (codex / claude-fallback) and exit status (OK/FAIL/TIMEOUT) before proceeding to the next
- **無人実行前提のため、失敗してもユーザーに継続確認しない。** FAIL/TIMEOUT のタスクは記録して自動的に次のタスクへ進む
- ただし **3 タスク連続で FAIL/TIMEOUT** した場合は環境・前提の問題（ビルド破損、Unity 起動不能など）の可能性が高いため、そこで実行を打ち切り、残タスクを SKIPPED として記録してサマリーへ進む
- 途中のタスクが FAIL でも後続タスクは独立して試行する（依存で連鎖失敗する場合は上記の連続失敗ガードで止まる）

## Validate Implementation

タスク実行ループが終わったら（打ち切り含む）、**ユーザーに確認せず**そのまま実装検証を実行する:

```
/kiro:validate-impl $1
```

実行条件と扱い:
- **1 つでも OK のタスクがあれば必ず 1 回実行する**（部分成功でも、できた分の実装を検証する価値があるため）
- OK がゼロ（全 FAIL/TIMEOUT/SKIPPED）の場合は実行せず、`SKIPPED (no completed tasks)` として記録
- **この検証はソフトゲート**: コマンドがプロジェクトに存在しない・エラーになった場合は `SKIPPED` として理由を記録し、サマリーへ進む。検証で問題が報告されても自動修正は試みない — 指摘内容をサマリーに転記するだけに留める（無人実行中に検証起点の修正ループへ入らない）
- サブコマンド出力内の「次のステップ」案内は無視する

## Summary

After all tasks complete, display a summary table:

| Task ID | Title | Engine | Result |
|---------|-------|--------|--------|
| ...     | ...   | codex / claude-fallback | OK/FAIL/TIMEOUT/SKIPPED |

サマリーテーブルの直後に **Validation Results** を必ず記載する:
- validate-impl: <PASSED / 指摘あり（内容の要約） / SKIPPED（理由）>
- 検証で報告された指摘事項の一覧（あれば）

Then suggest next steps:
- If all OK and validation passed: 実装完了。指摘事項があればそのレビューを促す
- If any FAIL/TIMEOUT: Review logs and fix issues manually, then re-run `/kiro:spec-run $1`（tasks.md の未チェックタスクだけが再実行される）
- 連続失敗ガードで打ち切った場合: 打ち切り理由（直近の失敗ログの要点）を明記する
- フォールバック発生回数を集計表示（例: `claude -p フォールバック: 2/15 タスク`）。常時フォールバックしている場合は Codex のクォータ確認を促す
