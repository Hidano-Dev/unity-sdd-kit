---
description: Read a multi-spec plan document and run /kiro:spec-init-dig for each pending spec sequentially, updating plan status as it goes (run in a fresh session after /clear; interactive — dig interviews require the user)
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, SlashCommand, TodoWrite, ToolSearch, AskUserQuestion
argument-hint: [plan-name] [spec-name]
---

# Multi-Spec Batch Initializer

## Purpose

`/kiro:spec-split` が作成したプランドキュメント(`.kiro/multi-spec/{plan-name}.md`)を読み、Status が PENDING の各 Spec に対して `/kiro:spec-init-dig` を**推奨実行順に 1 つずつ**実行する。各 Spec の完了ごとにプランドキュメントの Status を更新するため、途中で中断しても `/clear` 後に同じコマンドを再実行すれば続きから再開できる。

**注意: `/kiro:spec-run` と違い、これは無人実行ではない。** 各 Spec の dig インタビューで `AskUserQuestion` に答える必要があるため、ユーザーが応答できる状態で実行すること。

Spec 間を逐次にするのは dig インタビューが対話的で並列化できないため。「並走」は本コマンド完了後、各 Spec が独立に `/kiro:spec-run` へ進める状態になることで実現される。

## Parse Arguments

- Plan name: `$1`(任意)
- Spec name: `$2`(任意 — 指定した場合、その 1 Spec のみ実行)

### Locate the Plan

1. `$1` があれば `.kiro/multi-spec/$1.md` を読む。存在しなければエラーで中断し、`.kiro/multi-spec/*.md` の一覧を提示する。
2. `$1` が無い場合、Glob `.kiro/multi-spec/*.md` で探す:
   - PENDING(または IN_PROGRESS)の Spec を含むプランがちょうど 1 つ → それを使う
   - 0 件 → 中断: `❌ 実行待ちの Spec を含むプランがありません。先に /kiro:spec-split を実行してください。`
   - 複数 → 中断し、候補一覧を提示して `$1` での指定を求める

## Preflight

1. プランドキュメント全体を読み、「全体コンテクスト」「共通の決定済み事項」「Spec 一覧」と各 `## Spec:` 節を把握する。
2. 対象 Spec を決める:
   - `$2` 指定あり → その Spec のみ(Status が DONE なら中断してその旨を報告)
   - 指定なし → Status: PENDING の全 Spec を「Spec 一覧(推奨実行順)」の順に。依存欄がある場合、依存先が未完了(PENDING/FAILED)の Spec は依存先の後ろに回す
3. **IN_PROGRESS の Spec が残っている場合**(前回の中断):
   - `.kiro/specs/{feature-name}/tasks.md` が存在する → 実は完了している。Status を DONE に直して続行
   - 中途半端な生成物のみ存在する → その Spec は FAILED (interrupted) として記録し、サマリーで復旧方法(spec ディレクトリを削除して Status を PENDING に戻す、または `/kiro:spec-requirements` 以降を手動で個別実行)を案内。**自動では再実行しない**(feature 名の重複で `-2` サフィックスのゴミディレクトリが生えるため)
4. 対象が 0 件なら「全 Spec 処理済み」のサマリーを出して終了。
5. `.kiro/settings/templates/specs/` 配下のテンプレート(`init.json`, `requirements-init.md`)の存在を確認。無ければ**バッチ全体を中断**する(全 Spec が同じ理由で失敗するため)。

## Progress Tracking

TodoWrite を対象 Spec 1 件につき 1 タスクで初期化する:

```json
[
  {"content": "Init spec: {kebab-name}", "activeForm": "Initializing spec: {kebab-name}", "status": "pending"}
]
```

## Execute Specs (sequential)

各対象 Spec について、以下を順に行う:

### Step 1: Mark IN_PROGRESS

プランドキュメントの当該 `## Spec:` 節の Status と「Spec 一覧」テーブルの Status を `IN_PROGRESS` に更新する(中断検知のため、実行**前**に書く)。TodoWrite も `in_progress` へ。

### Step 2: Compose Description

プランの内容から `/kiro:spec-init-dig` に渡す説明文を 1 段落で組み立てる(プランドキュメントと同じ言語で書く):

```
{kebab-name}: {概要を 1–3 文}。詳細な背景・決定済み事項・スコープ・未決事項は .kiro/multi-spec/{plan-name}.md の「全体コンテクスト」「共通の決定済み事項」「Spec: {kebab-name}」の各節に記載されており、requirements 生成・dig インタビュー・design の前提として必ず読み込むこと。
```

依存先 Spec が処理済みの場合は `関連 spec: .kiro/specs/{dependency-feature}/ も参照。` を追記する。依存先が FAILED/未処理の場合はその旨(「依存先 {name} は未作成。インターフェースはプランドキュメントの記載を暫定の前提とする」)を追記して続行する。

### Step 3: Run spec-init-dig

```
/kiro:spec-init-dig "{description}"
```

`/kiro:spec-init-dig` の全フェーズ(init → requirements → dig → validate-gap → design → validate-design → tasks)が走る。実行中は以下のオーバーライドを適用する:

- **Feature 名**: Phase 1 の名前生成では `$ARGUMENTS` からの変換ではなく、プランの推奨 feature 名 `{kebab-name}` をそのまま使う(一意性チェックによる `-2` サフィックスは通常通り)
- **Dig インタビュー**: Step 4.1 のコンテクスト収集で**プランドキュメントを必ず読む**。プランの「共通の決定済み事項 (G-x)」「この Spec 固有の決定済み事項 (S-x)」は決定済みとして扱い、**再質問しない**(requirements.md の Decisions 節へ出典付き — `per plan G-1` のように — で転記する)。質問は「未決事項(dig で確認すべき候補)」と、requirements 生成で新たに露出した前提を優先する
- **Next Step 案内の無視**: spec-init-dig の Final Summary が案内する次ステップ(`/kiro:spec-run` など)はここでは実行しない — バッチの次の Spec へ進む

### Step 4: Record Result

- **成功**(tasks.md まで生成された): プランドキュメントを更新 — 当該節の Status を `DONE`、`Feature dir:` に `.kiro/specs/{feature-name}/` を記入、「Spec 一覧」テーブルも `DONE` に。TodoWrite を `completed` へ
- **失敗**: Status を `FAILED` にし、当該節に `- Failure: {理由の要約}` を追記。TodoWrite はそのタスクを failed 扱いにし、**次の Spec へ自動継続**する
- ただし **2 Spec 連続で FAILED** した場合は環境・前提の問題の可能性が高いため打ち切り、残りを `SKIPPED` として記録してサマリーへ進む
- **例外 — 監査違反**: spec-init-dig が validate-gap の**監査違反**（research.md 以外への許可外書き込み・ベースライン改ざん・`APPEND_VIOLATION`）で停止した場合は、通常の FAILED として次の Spec へ進んではならない。作業ツリーが変更・破損された可能性があるため、**バッチ全体をそこで停止**し、Status を `FAILED (audit violation)` と記録して違反内容を報告し、ユーザーの判断を待つ

### Step 5: Continue

次の Spec へ**ユーザー確認なしで**進む(dig インタビュー内の質問は例外)。各 Spec の完了時に 1 行だけ進捗を出力する:

```
✅ {kebab-name} done ({n}/{total}) → next: {next-name}
```

セッションが長くなりコンテクスト圧縮が発生しても、プランドキュメントの Status が正なので問題ない。ユーザーが途中で中断した場合は `/clear` 後に `/kiro:spec-init-batch {plan-name}` を再実行すれば PENDING の続きから再開する。

## Final Summary

全対象 Spec の処理後(打ち切り含む)、以下を出力する:

```
✅ spec-init-batch complete!

## Plan
- File: .kiro/multi-spec/{plan-name}.md

| # | Spec | Feature dir | Result |
|---|------|-------------|--------|
| 1 | ...  | .kiro/specs/... | DONE / FAILED / SKIPPED |

## Failures
{FAILED があれば理由と復旧手順。無ければ省略}

## Next Steps
1. 各 Spec の design.md / tasks.md をレビュー
2. 実装は依存順に: /kiro:spec-run {feature-name-1} → /kiro:spec-run {feature-name-2} → …
   (依存関係の無い Spec 同士は別セッション・別 worktree で並走させてもよい)
```

## Execution Rules

- Spec 間の遷移でユーザー確認をしない — 対話が発生するのは各 Spec の dig インタビュー内のみ
- プランドキュメントの Status 更新は各 Spec の**開始前(IN_PROGRESS)と終了直後(DONE/FAILED)**に必ず行う — 再開可能性の生命線
- 1 つの Spec の失敗で残りを止めない(2 連続 FAILED の打ち切りガードのみ例外)
- spec-init-dig 内部のソフトゲート方針(validate の SKIPPED 継続など)はそのまま尊重する
- 中間出力は簡潔に。詳細は Final Summary に集約する
