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
- `.kiro/specs/<feature>/spec.json` で `approvals.requirements.approved` / `approvals.design.approved` / `approvals.tasks.approved` がすべて true（レビュー前の草案に対して無人実装を始めない。`ready_for_implementation` は dev-orchestrator 経由でしか立たないため判定に使わない）

いずれかを満たさない spec があれば、その spec 名と理由を明示して（tasks 未生成なら `/kiro:spec-tasks <feature>`、未承認なら各フェーズのレビューと承認を）先に完了するよう案内し、その spec を batch から除外する。除外後に残りが 1 spec 以下なら本 skill は終了（`/kiro:spec-run` に誘導）。

Codex の存在確認:
- `codex --version` を実行。成功すれば codex-first モード。
- 失敗（コマンド未インストール）した場合は警告を出し、最初から `claude -p` のみで実行するモードに自動降格する（ユーザー確認は不要）。

## Extract Tasks

各 feature の `.kiro/specs/<feature>/tasks.md` を順番に読み、未完了タスク（`- [ ] <number>` または `- [ ]* <number>`）を抽出する。

各タスクから以下を抽出:
- Feature name (引数の宣言順を保持)
- Task ID (例: "1.1", "2", "4.3")
- Task title (ID の後ろのテキスト)
- Depends（タスク詳細の `_Depends: X.Y, ..._` に列挙されたタスク ID。無ければ空）

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

各タスクは `git add -A` でコミットするため、失敗したタスクの途中の変更が残っていると、次のタスクのコミットや検証に混ざって帰属と検証が壊れる。git の追跡外（ignored）の設定ファイル（`.env` など）の書き換えも同様に後続へ残る。これを防ぐため、次を必ず守る。

**開始前（1 回だけ）**

```bash
umask 077
run_dir=$(mktemp -d)                       # この実行専用の私有ディレクトリ（ログ・退避物の置き場）
run_id=$(date +%Y%m%d-%H%M%S)-$$           # 退避ブランチ名を実行ごとに一意にするための ID
```

- `git status --porcelain` が空であることを確認する。未コミットの変更があれば実行を開始せず、その旨を報告して終了する（既存の変更を巻き込まないためのハードゲート。無人実行でも例外にしない）。
- Bash ツールの呼び出し間でシェル変数は保持されないため、上で決まった `run_dir` / `run_id` の実際の値を以降のコマンドに埋め込んで使う（`pre_head` / `attempt` も同様）。
- タスクのログは `$run_dir` の下に置く（例: `"$run_dir/codex-<attempt>.log"`）。共有の `/tmp` 固定パスは使わない。

**各試行の開始直前**（フォールバックも別の試行として数える）: 試行番号 `attempt` を 1 つ進め、`pre_head=$(git rev-parse HEAD)` を記録し、**その時点の** ignored ファイルのスナップショットを取る（成功したタスクが意図して変えた ignored ファイルを、後続の失敗時に巻き戻さないため、基準は試行ごとに取り直す）:

```bash
snap="$run_dir/a$attempt"; mkdir -p "$snap"
# 生成物（Unity の Library/Temp/Logs/obj/UserSettings やビルド出力）を除いた ignored ファイル
gen_re='(^|/)(Library|Temp|Logs|obj|UserSettings|Builds?|MemoryCaptures|node_modules)/'
git ls-files -o -i --exclude-standard -z | grep -zvE "$gen_re" > "$snap/ignored.list" || true
tar --null -T "$snap/ignored.list" -cf "$snap/ignored.tar" 2>/dev/null || true
(xargs -0 -r sha256sum < "$snap/ignored.list") > "$snap/ignored.sha256" 2>/dev/null || true
```

**試行が OK 以外（FAIL / TIMEOUT / レビュー REJECTED / 依存未充足で中断）で終わったとき、および使用制限で claude -p にフォールバックする前**は、次の手順でその試行の開始時点へ戻す。失敗した作業は捨てずに退避する:

1. 追跡対象・untracked の変更があれば `git stash push -u -m "spec-run failed: <feature> <task_id> (run $run_id, attempt $attempt)"`
2. HEAD が `pre_head` から進んでいれば `git branch "spec-run-failed/$run_id/<feature>/<task_id>-$attempt" HEAD` で退避してから `git reset --hard "$pre_head"`
3. ignored ファイルを**その試行の**スナップショット（`$run_dir/a$attempt`）と比べる（`gen_re` に当たる生成物は対象外）。試行中に増えた・変わった ignored ファイルは `"$run_dir/failed-$attempt/"` へ移動して退避し、変更・削除されたものは `"$run_dir/a$attempt/ignored.tar"` から復元する
4. 退避先（stash メッセージ / ブランチ名 / `$run_dir/failed-*`）をサマリーに記録する

**実装エンジンが OK を出したタスクでも**、Step 4 のレビューに入る前に未コミットの変更が残っていれば同じく stash して記録する（コミット漏れを次のタスクに持ち込まず、レビューはコミット済みの内容だけを対象にする）。ignored ファイルが変わっていれば、意図した変更かどうかをサマリーで報告する。

**終了時**: ログとスナップショットは不要になったら削除してよいが、退避物（`failed-*`）がある場合は残し、その場所をサマリーに明記する。

## Execute Tasks

統合タスクリストを順次（並列ではなく）に処理する。各タスクの実行手順:

### Step 1: codex exec を試行（codex 利用可の場合のみ）

```bash
codex exec --dangerously-bypass-approvals-and-sandbox - <<'CODEX_EOF' 2>&1 | tee "$run_dir/codex-$attempt.log"
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
Execute only this single task (<task_id> <task_title>) according to the instructions in AGENTS.md (auto-loaded by Codex) and the spec documents in .kiro/specs/<feature>/ (requirements.md, design.md, tasks.md). Before starting, output the task name (<task_id> <task_title>). After completing the task, run UnityTestRunner to verify the result. If any file changes exist, run git add -A and then commit. The commit title must be the task name "<task_id> <task_title>" as-is. The commit body must contain a brief summary of what was done (files created/modified, key changes). Use a multi-line commit message with git commit -m "title" -m "body". Before implementing behavior, write or update the tests first and run them to confirm they fail; before the final line, print a section that starts with "RED_PHASE_OUTPUT:" containing that failing test output (or "RED_PHASE_OUTPUT: N/A - <reason>" for non-behavioral tasks such as docs or config). Finally, output only OK or FAIL. tasks.txt is a user-managed file and must not be modified. After outputting OK or FAIL, complete the session without waiting for user input.
```

### Step 2: 結果判定

判定の優先順位（`/kiro:spec-run` と同等）:

1. **codex 出力末尾に `OK`** → 実装完了。Step 4 の独立レビューへ進む（APPROVED になるまで OK として記録しない）
2. **codex 出力末尾に `FAIL`** → タスク失敗（FAIL として記録、自動的に次のタスクへ）
3. **codex_exit が非ゼロ かつ ログに使用制限シグネチャあり** → 使用制限ヒット → Working Tree Baseline の手順で `pre_head` に戻してから Step 3 へフォールバック
4. **codex_exit が非ゼロ かつ シグネチャ無し** → 通常の実行失敗（FAIL として記録、自動的に次のタスクへ）
5. **タイムアウト（30 分）** → TIMEOUT として記録、自動的に次のタスクへ

使用制限シグネチャの検出（case-insensitive）:

```bash
grep -iE 'rate.?limit|usage.?limit|quota|\b429\b|too many requests|exceeded your|try again later' "$run_dir/codex-$attempt.log"
```

このパターンに該当しても誤検知の可能性はあるため、**判定は必ず「exit code 非ゼロ AND grep ヒット」の AND 条件**で行う。OK/FAIL が明示出力されているケースが優先。

### Step 3: claude -p フォールバック（使用制限検知時のみ）

```bash
unset CLAUDECODE && echo "" | claude -p "<claude_prompt>" --max-turns 60 --enable-auto-mode --verbose 2>&1 | tee "$run_dir/claude-$attempt.log"
claude_exit=${PIPESTATUS[0]}   # tee ではなく claude 自身の終了コードで判定する
```

> **Note:** `unset CLAUDECODE` は親セッション（このスクリプトを呼んでいる claude）からのネスト起動を許可するため。

`<claude_prompt>` は以下（codex_prompt とほぼ同じだが AGENTS.md → CLAUDE.md、`<feature>` は当該タスクの spec 名で置換）:

```
Execute only this single task (<task_id> <task_title>) according to the instructions in CLAUDE.md and the spec documents in .kiro/specs/<feature>/ (requirements.md, design.md, tasks.md). Before starting, output the task name (<task_id> <task_title>). After completing the task, run UnityTestRunner to verify the result. If any file changes exist, run git add -A and then commit. The commit title must be the task name "<task_id> <task_title>" as-is. The commit body must contain a brief summary of what was done (files created/modified, key changes). Use a multi-line commit message with git commit -m "title" -m "body". Before implementing behavior, write or update the tests first and run them to confirm they fail; before the final line, print a section that starts with "RED_PHASE_OUTPUT:" containing that failing test output (or "RED_PHASE_OUTPUT: N/A - <reason>" for non-behavioral tasks such as docs or config). Finally, output only OK or FAIL. tasks.txt is a user-managed file and must not be modified. After outputting OK or FAIL, complete the session without waiting for user input.
```

フォールバック後の結果判定:
- 出力末尾の `OK` / `FAIL` で判定。`OK` の場合も Step 4 の独立レビューを通す。
- `claude_exit` が非ゼロ → FAIL 扱い。
- タイムアウト → TIMEOUT 扱い。
- claude 側でも使用制限を踏んだ場合は FAIL として記録し、自動的に次のタスクへ進む（さらなるフォールバック先は無い。連続失敗ガードに委ねる）。

### Step 4: 独立レビュー（実装エンジンが OK を出したタスクのみ）

実装したエージェント自身の `OK` だけでタスクを成功扱いにしない。後続タスクが未レビューの変更を前提に進まないよう、**次のタスクへ進む前に**、実装とは別系統のエンジンでそのタスクの差分をレビューする:

- レビューエンジン: 実装が codex なら `claude -p`。実装が claude（使用制限によるフォールバック）の場合、Codex は制限中の可能性が高いので `codex exec` は使わず、このセッション（オーケストレーター）自身が実装とは独立にレビューする。どちらも使えない場合もこのセッション自身がレビューする。
- レビュー実行が使用制限（Step 2 と同じシグネチャ）で失敗した場合は REJECTED にせず、このセッション自身のレビューに切り替えてやり直す（制限による失敗で正しい実装を巻き戻さない）。
- レビュー対象: この試行で作られたコミット（`git diff "$pre_head"..HEAD`）**だけ**。レビューの前に、作業ツリーに未コミットの変更が残っていれば Working Tree Baseline の手順 1 で stash して「コミット漏れ」としてサマリーに記録し、レビューした内容とブランチに残る内容を一致させる（承認された変更を後から捨てることがないように）。
- 実装者の報告: 実装エンジンの出力を保存した試行ログ（`$run_dir/codex-<attempt>.log` または `$run_dir/claude-<attempt>.log`）をレビュアーに渡す。kiro-review は behavioral task の `RED_PHASE_OUTPUT` を必須入力とするため、実装プロンプトでその出力を求めている。ログに `RED_PHASE_OUTPUT:` が無い behavioral task は、レビュアーの判定どおり REJECTED として扱う。

```
Review only task <task_id> <task_title> of spec .kiro/specs/<feature>/ (read requirements.md, design.md and tasks.md yourself). The implementer's report is the attempt log at <attempt_log>; take RED_PHASE_OUTPUT from its "RED_PHASE_OUTPUT:" section (use it as the status report input that kiro-review expects, and verify it independently). Run `git diff <pre_head>..HEAD` to see the committed changes (that diff is the whole scope of this review); do not trust the implementer's summary. Apply the kiro-review protocol (.agents/skills/kiro-review/SKILL.md): check that the change implements this task's requirements and design, stays within the task's boundary (no unrelated files or other tasks' work), includes or updates the tests the task requires and that those tests were run, and introduces no regressions or placeholder code. Do not modify any files. End with exactly:
## Review Verdict
- VERDICT: APPROVED | REJECTED
- FINDINGS: <one line per finding, or "none">
```

- `## Review Verdict` ブロックの `- VERDICT:` からだけ判定する（周囲の文章から推測しない）。判定が読めない場合は 1 回だけ再依頼し、それでも読めなければ REJECTED として扱う。
- **APPROVED** → すぐには OK にしない。`kiro-verify-completion`（`.agents/skills/kiro-verify-completion/SKILL.md`）に従い、このセッション自身が**その場で新しく**対象プロジェクトの検証コマンド（リポジトリ固有のテストコマンド、無ければ `.claude/rules/unity-sdd.md` の既定。Unity 以外ならリポジトリの標準テストコマンド）を実行し、成功を確認してから OK として記録する（tasks.md のチェックとコミットは実装エンジンが行ったものをそのまま使う）。
- 完了確認でテストが失敗した、または検証コマンドを実行できなかった場合は `FAIL (verify)` として記録し、REJECTED と同じく試行の開始時点に戻す（実行できなかった理由もサマリーに残す）。
- **REJECTED** → タスクを `FAIL (review)` として記録し、指摘をサマリーに転記したうえで、Working Tree Baseline の手順でこの試行の開始時点に戻す（コミットは退避ブランチへ逃がす）。無人実行中に修正ループへは入らない。
- レビュー実行が使用制限以外の理由で失敗・タイムアウトした場合は REJECTED と同じに扱う（未レビューの変更を残さない）。

### Execution Rules

- 統合キューを **並列ではなく順次** に実行する
- 各実行（codex / claude いずれも）に 30 分タイムアウト（1800 秒）を Bash tool の timeout パラメータで設定
- フォールバック発動時は **そのタスクのみ** claude -p に切り替える。次のタスクではまた codex から試行する（永続切替はしない）
- After each task completes, report which spec / engine was used (codex / claude-fallback) and exit status (OK/FAIL/TIMEOUT) before proceeding to the next
- **依存関係**: 各タスクの実行前に、tasks.md にある当該タスクの `_Depends: X.Y, ..._`（同じ spec 内のタスク ID）を確認する。参照先が tasks.md で `[x]` でもなく、この実行で OK（レビュー APPROVED）にもなっていない場合（FAIL / TIMEOUT / SKIPPED / 未実行）は、そのタスクを実行せず `SKIPPED (blocked by X.Y)` として記録する。さらに、tasks.md では記述順が主要な依存関係なので、`(P)` の付いていないタスクは**同じ spec 内で直前の leaf タスク**にも暗黙に依存するとみなし、直前のタスクが `[x]` でもこの実行で OK でもなければ同様に `SKIPPED (blocked by X.Y)` とする（`(P)` のタスクは明示した `_Depends:` だけを見る）。ブロックは推移的に伝わる（ブロックされたタスクに依存するタスクもブロックする）。ブロックによる SKIPPED は連続失敗ガードの回数に数えない
- **無人実行前提のため、失敗してもユーザーに継続確認しない。** FAIL/TIMEOUT のタスクは記録し、Working Tree Baseline の手順で `pre_head` に戻して（作業は退避して）から自動的に次のタスクへ進む
- ただし **3 タスク連続で FAIL/TIMEOUT（レビュー REJECTED を含む）** した場合は環境・前提の問題（ビルド破損、Unity 起動不能など）の可能性が高いため、そこで実行を打ち切り、残タスク（後続 spec を含む）を SKIPPED として記録して実装検証へ進む
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
| ...  | ...     | ...   | codex / claude-fallback | OK/FAIL/FAIL (review)/FAIL (verify)/TIMEOUT/SKIPPED/SKIPPED (blocked by X.Y) |

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
- 退避した失敗タスク（stash メッセージ / `spec-run-failed/<run_id>/...` ブランチ / `$run_dir/failed-*`）を一覧表示し、内容を確認して不要なら削除するよう促す
- spec 単位の小計（spec1: 19/19 OK, spec2: 18/19 OK 1 FAIL 等）も表示する
