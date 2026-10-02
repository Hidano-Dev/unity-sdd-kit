---
description: Run all pending spec tasks ACROSS MULTIPLE specs sequentially via codex exec, with automatic fallback to claude -p on Codex usage-limit. Concatenates each spec's tasks into one queue and processes them in declared order.
allowed-tools: Read, Bash, Glob, Grep
argument-hint: <feature-name-1> <feature-name-2> [feature-name-3] ...
---

# Multi-Spec Batch Runner

複数の spec のタスクを **1 本のキュー** に連結して順次実行する。`/kiro:spec-run` を 1 spec ずつ手動で起動する代わりに、1 コマンドで複数 spec を「連続実行」する。

各タスクは **codex exec を第一優先**で実行し、Codex の使用制限（rate / usage / quota）を踏んだ場合のみ **そのタスクだけ `claude -p` にフォールバック**して再実行する。使用制限は時間で回復するため、次のタスクではまた codex から試す。

> **本 skill は同時並行実行ではない**。Unity Editor は 1 プロジェクトに 1 インスタンスしか開けないため、真の並列実行はサポートしない。本 skill が提供するのは「複数 spec のタスクを 1 コマンドで連続実行する」自動化のみ。

## Parse Arguments

引数: 1 個以上の feature-name（順に `$1`, `$2`, ...）

引数が 1 個以下の場合は、ユーザーに「`/kiro:spec-run-multi` は 2 spec 以上に使用してください。1 spec のみなら `/kiro:spec-run <feature-name>` を使ってください」と案内して終了。

## Validate

各 feature-name について以下を確認:
- `.kiro/specs/<feature>/` が存在する
- `.kiro/specs/<feature>/tasks.md` が存在する

いずれかが欠ける spec があれば、その spec 名を明示して `/kiro:spec-tasks <feature>` で tasks 生成を先に完了するよう案内し、その spec を batch から除外する。除外後に残りが 1 spec 以下なら本 skill は終了（`/kiro:spec-run` に誘導）。

Codex の存在確認:
- `codex --version` を実行。成功すれば codex-first モード。
- 失敗（コマンド未インストール）した場合は警告を出し、最初から `claude -p` のみで実行するモードに自動降格する（ユーザー確認は不要）。

## Extract Tasks

各 feature の `.kiro/specs/<feature>/tasks.md` を順番に読み、未完了タスク（`- [ ] <number>` または `- [ ]* <number>`）を抽出する。

各タスクから以下を抽出:
- Feature name (引数の宣言順を保持)
- Task ID (例: "1.1", "2", "4.3")
- Task title (ID の後ろのテキスト)

Container task（サブタスクを持つ親タスク）はスキップし、leaf-level（実行可能）のタスクのみを含める。

抽出結果を **引数の宣言順** に従って 1 リストに連結する。同 spec 内の順序は tasks.md の記述順を保持。

各タスクは `<feature_name> <task_id> <task_title>` の形式で 1 行に整形する。

## Confirm with User

統合タスクリストを表示し、ユーザーに実行確認を求める。

表示内容:
- 対象 spec 名（複数）と各 spec のタスク件数
- 全タスク件数（連結後）
- タスク一覧（`<feature> <id> <title>` 形式、宣言順）
- 推定アプローチ: per-task に codex exec → 使用制限検知時のみ claude -p へフォールバック（タスクごとにリセット）。各実行 30 分タイムアウト
- Codex 利用可否（`codex --version` の結果）
- 注意: 「Unity Editor が起動している場合は、batchmode テスト実行で競合する可能性があるため Editor を閉じてから実行することを推奨」

## Execute Tasks

統合タスクリストを順次（並列ではなく）に処理する。各タスクの実行手順:

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

`<codex_prompt>` は以下（`<feature>` は当該タスクの spec 名で置換）:

```
Execute only this single task (<task_id> <task_title>) according to the instructions in AGENTS.md (auto-loaded by Codex) and the spec documents in .kiro/specs/<feature>/ (requirements.md, design.md, tasks.md). Before starting, output the task name (<task_id> <task_title>). After completing the task, run UnityTestRunner to verify the result. If any file changes exist, run git add -A and then commit. The commit title must be the task name "<task_id> <task_title>" as-is. The commit body must contain a brief summary of what was done (files created/modified, key changes). Use a multi-line commit message with git commit -m "title" -m "body". Finally, output only OK or FAIL. tasks.txt is a user-managed file and must not be modified. After outputting OK or FAIL, complete the session without waiting for user input.
```

### Step 2: 結果判定

判定の優先順位（`/kiro:spec-run` と同等）:

1. **codex 出力末尾に `OK`** → タスク成功（OK として記録、次のタスクへ）
2. **codex 出力末尾に `FAIL`** → タスク失敗（FAIL として記録、ユーザーに継続確認）
3. **codex_exit が非ゼロ かつ ログに使用制限シグネチャあり** → 使用制限ヒット → Step 3 へフォールバック
4. **codex_exit が非ゼロ かつ シグネチャ無し** → 通常の実行失敗（FAIL として記録、ユーザーに継続確認）
5. **タイムアウト（30 分）** → TIMEOUT として記録、ユーザーに継続確認

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

`<claude_prompt>` は以下（codex_prompt とほぼ同じだが AGENTS.md → CLAUDE.md、`<feature>` は当該タスクの spec 名で置換）:

```
Execute only this single task (<task_id> <task_title>) according to the instructions in CLAUDE.md and the spec documents in .kiro/specs/<feature>/ (requirements.md, design.md, tasks.md). Before starting, output the task name (<task_id> <task_title>). After completing the task, run UnityTestRunner to verify the result. If any file changes exist, run git add -A and then commit. The commit title must be the task name "<task_id> <task_title>" as-is. The commit body must contain a brief summary of what was done (files created/modified, key changes). Use a multi-line commit message with git commit -m "title" -m "body". Finally, output only OK or FAIL. tasks.txt is a user-managed file and must not be modified. After outputting OK or FAIL, complete the session without waiting for user input.
```

フォールバック後の結果判定:
- 出力末尾の `OK` / `FAIL` で判定。
- exit code 非ゼロ → FAIL 扱い。
- タイムアウト → TIMEOUT 扱い。
- claude 側でも使用制限を踏んだ場合は素直に FAIL/エラーとして報告し、ユーザーに継続確認する（さらなるフォールバック先は無い）。

### Execution Rules

- 統合キューを **並列ではなく順次** に実行する
- 各実行（codex / claude いずれも）に 30 分タイムアウト（1800 秒）を Bash tool の timeout パラメータで設定
- フォールバック発動時は **そのタスクのみ** claude -p に切り替える。次のタスクではまた codex から試行する（永続切替はしない）
- After each task completes, report which spec / engine was used (codex / claude-fallback) and exit status (OK/FAIL/TIMEOUT) before proceeding to the next
- If a task fails or times out, ask the user whether to continue with the remaining tasks or stop
- spec の境界をまたいでも処理は連続する（spec1 の途中で FAIL してもユーザーが続行を選べば spec1 の残り → spec2 へ進む）

## Summary

全タスク完了後、以下のサマリ表を表示する:

| Spec | Task ID | Title | Engine | Result |
|------|---------|-------|--------|--------|
| ...  | ...     | ...   | codex / claude-fallback | OK/FAIL/TIMEOUT |

その後、次のステップを提案する:
- すべての spec で全タスク OK の場合: 各 spec に対し `/kiro:validate-impl <feature>` で実装検証を勧める
- 一部 FAIL の場合: 対象 spec とタスクを列挙し、ログ確認 + 手動修正 + 再実行を勧める
- フォールバック発生回数を集計表示（例: `claude -p フォールバック: 2/38 タスク`）。常時フォールバックしている場合は Codex のクォータ確認を促す
- spec 単位の小計（spec1: 19/19 OK, spec2: 18/19 OK 1 FAIL 等）も表示する
