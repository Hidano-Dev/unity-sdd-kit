---
description: Run all pending spec tasks ACROSS MULTIPLE specs sequentially via codex exec, with automatic fallback to claude -p on Codex usage-limit, then run validate-impl for each spec. Concatenates each spec's tasks into one queue and processes them in declared order (unattended batch execution — starts immediately without confirmation)
allowed-tools: Read, Bash, Glob, Grep, SlashCommand
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

## Announce and Start Immediately

**ユーザーに確認しない。入力も待たない。** `/kiro:spec-run` と同じく無人（放置・夜間）実行を前提とし、このコマンドを起動したこと自体を実行の承認とみなす。

実行前に、統合タスクリストを 1 回だけ表示する（情報提示のみ）:
- 対象 spec 名（複数）と各 spec のタスク件数
- 全タスク件数（連結後）
- タスク一覧（`<feature> <id> <title>` 形式、宣言順）
- 推定アプローチ: per-task に codex exec → 使用制限検知時のみ claude -p へフォールバック（タスクごとにリセット）。各実行 30 分タイムアウト
- Codex 利用可否（`codex --version` の結果）
- 注意: 「Unity Editor が起動している場合は、batchmode テスト実行で競合する可能性があるため Editor を閉じてから実行することを推奨」

表示したら、同じターンのまま直ちにタスク実行へ進む。実行前に止まるのは、検証の結果として実行可能な spec が 1 つ以下になった場合と、全 spec で未完了タスクがゼロの場合だけ。

## Working Tree Baseline（失敗したタスクの変更を後続へ持ち込まない）

各タスクは `git add -A` でコミットするため、失敗したタスクの途中の変更が残っていると、次のタスクのコミットに混ざって帰属と検証が壊れる。これを防ぐため、次を必ず守る:

- **開始前**: `git status --porcelain` が空であることを確認する。未コミットの変更があれば実行を開始せず、その旨を報告して終了する（既存の変更を巻き込まないためのハードゲート。無人実行でも例外にしない）。
- **各タスクの開始直前**: `pre_head=$(git rev-parse HEAD)` を記録する。
- **タスクが OK 以外（FAIL / TIMEOUT）で終わったら**、次のタスクへ進む前に作業ツリーを `pre_head` の状態へ戻す。失敗したタスクの作業は捨てずに退避する:
  1. 未コミットの変更があれば `git stash push -u -m "spec-run failed: <feature> <task_id>"`
  2. HEAD が `pre_head` から進んでいれば `git branch "spec-run-failed/<feature>/<task_id>" HEAD` で退避してから `git reset --hard "$pre_head"`
  3. 退避先（stash メッセージ / ブランチ名）をサマリーに記録する
- **使用制限で claude -p にフォールバックする前**にも同じ手順で `pre_head` に戻す（codex の途中の変更をフォールバック実行に混ぜない）。
- **OK のタスクでも**、終了後に未コミットの変更が残っていれば同じく stash して記録する（コミット漏れを次のタスクに持ち込まない）。

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
2. **codex 出力末尾に `FAIL`** → タスク失敗（FAIL として記録、自動的に次のタスクへ）
3. **codex_exit が非ゼロ かつ ログに使用制限シグネチャあり** → 使用制限ヒット → Working Tree Baseline の手順で `pre_head` に戻してから Step 3 へフォールバック
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

`<claude_prompt>` は以下（codex_prompt とほぼ同じだが AGENTS.md → CLAUDE.md、`<feature>` は当該タスクの spec 名で置換）:

```
Execute only this single task (<task_id> <task_title>) according to the instructions in CLAUDE.md and the spec documents in .kiro/specs/<feature>/ (requirements.md, design.md, tasks.md). Before starting, output the task name (<task_id> <task_title>). After completing the task, run UnityTestRunner to verify the result. If any file changes exist, run git add -A and then commit. The commit title must be the task name "<task_id> <task_title>" as-is. The commit body must contain a brief summary of what was done (files created/modified, key changes). Use a multi-line commit message with git commit -m "title" -m "body". Finally, output only OK or FAIL. tasks.txt is a user-managed file and must not be modified. After outputting OK or FAIL, complete the session without waiting for user input.
```

フォールバック後の結果判定:
- 出力末尾の `OK` / `FAIL` で判定。
- exit code 非ゼロ → FAIL 扱い。
- タイムアウト → TIMEOUT 扱い。
- claude 側でも使用制限を踏んだ場合は FAIL として記録し、自動的に次のタスクへ進む（さらなるフォールバック先は無い。連続失敗ガードに委ねる）。

### Execution Rules

- 統合キューを **並列ではなく順次** に実行する
- 各実行（codex / claude いずれも）に 30 分タイムアウト（1800 秒）を Bash tool の timeout パラメータで設定
- フォールバック発動時は **そのタスクのみ** claude -p に切り替える。次のタスクではまた codex から試行する（永続切替はしない）
- After each task completes, report which spec / engine was used (codex / claude-fallback) and exit status (OK/FAIL/TIMEOUT) before proceeding to the next
- **無人実行前提のため、失敗してもユーザーに継続確認しない。** FAIL/TIMEOUT のタスクは記録し、Working Tree Baseline の手順で `pre_head` に戻して（作業は退避して）から自動的に次のタスクへ進む
- ただし **3 タスク連続で FAIL/TIMEOUT** した場合は環境・前提の問題（ビルド破損、Unity 起動不能など）の可能性が高いため、そこで実行を打ち切り、残タスク（後続 spec を含む）を SKIPPED として記録して実装検証へ進む
- spec の境界をまたいでも処理は連続する（spec1 の途中で FAIL しても spec1 の残り → spec2 へ進む）

## Validate Implementation

タスク実行ループが終わったら（打ち切り含む）、**ユーザーに確認せず**、引数の宣言順に **spec ごとに** 実装検証を実行する:

```
/kiro:validate-impl <feature>
```

実行条件と扱い（`/kiro:spec-run` と同じ）:
- **その spec に 1 つでも OK のタスクがあれば必ず 1 回実行する**（部分成功でも、できた分の実装を検証する価値があるため）
- その spec の OK がゼロ（全 FAIL/TIMEOUT/SKIPPED）の場合は実行せず、`SKIPPED (no completed tasks)` として記録
- **この検証はソフトゲート**: コマンドがプロジェクトに存在しない・エラーになった場合は `SKIPPED` として理由を記録し、次の spec の検証へ進む。検証で問題が報告されても自動修正は試みない — 指摘内容をサマリーに転記するだけに留める（無人実行中に検証起点の修正ループへ入らない）
- **判定の記録**: validate-impl の DECISION（`GO` / `NO-GO` / `MANUAL_VERIFY_REQUIRED`）を spec ごとにそのまま記録する。`MANUAL_VERIFY_REQUIRED` は「重大な指摘なし」ではなく**独立した非通過結果**であり、GO に丸めない。不足している検証手順・環境前提もあわせて転記する
- タスクが OK でも、実装者自身の OK だけで spec を成功扱いにしない。spec の成否は validate-impl の DECISION で判断する
- サブコマンド出力内の「次のステップ」案内は無視する

## Summary

全タスクと検証の完了後、以下のサマリ表を表示する:

| Spec | Task ID | Title | Engine | Result |
|------|---------|-------|--------|--------|
| ...  | ...     | ...   | codex / claude-fallback | OK/FAIL/TIMEOUT/SKIPPED |

サマリーテーブルの直後に、spec ごとの **Validation Results** を必ず記載する:

| Spec | Tasks | validate-impl DECISION | 指摘事項 |
|------|-------|------------------------|----------|
| ...  | 19/19 OK | GO / NO-GO（要約） / MANUAL_VERIFY_REQUIRED（不足している検証手順・環境前提） / SKIPPED（理由） | ... |

- GO 以外はいずれも**非通過**として扱う（呼び出し元のゲート判定に DECISION をそのまま伝える。MANUAL_VERIFY_REQUIRED を「指摘なし」扱いにしない）

その後、次のステップを提案する:
- 全 spec が全タスク OK かつ validate-impl GO の場合: 実装完了。指摘事項があればそのレビューを促す
- MANUAL_VERIFY_REQUIRED の spec がある場合: 完了扱いにせず、不足している検証手順を明示して手動検証を促す
- FAIL/TIMEOUT がある場合: 対象 spec とタスクを列挙し、ログ確認 + 手動修正のうえ `/kiro:spec-run <feature>`（単一 spec）または本コマンドで再実行するよう勧める（tasks.md の未チェックタスクだけが再実行される）
- 連続失敗ガードで打ち切った場合: 打ち切り理由（直近の失敗ログの要点）を明記する
- フォールバック発生回数を集計表示（例: `claude -p フォールバック: 2/38 タスク`）。常時フォールバックしている場合は Codex のクォータ確認を促す
- 退避した失敗タスク（stash メッセージ / `spec-run-failed/...` ブランチ）を一覧表示し、内容を確認して不要なら削除するよう促す
- spec 単位の小計（spec1: 19/19 OK, spec2: 18/19 OK 1 FAIL 等）も表示する
