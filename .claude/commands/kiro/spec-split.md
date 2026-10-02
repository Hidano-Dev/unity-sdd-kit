---
description: Split the current brainstorming session into multiple specs and write a self-contained multi-spec plan document (run in the brainstorm session, before /clear)
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, TodoWrite, ToolSearch, AskUserQuestion
argument-hint: [plan-name]
---

# Multi-Spec Split Planner

## Purpose

ブレストの結果「複数の Spec に分けて実装すべき」という結論に至ったとき、**その場(ブレストしたセッション内)で**実行するコマンド。現在のセッションに蓄積された文脈を分析し、各 Spec の概要とコンテクストを自己完結したプランドキュメントにまとめる:

```
.kiro/multi-spec/{plan-name}.md
```

このドキュメントは `/clear` 後に `/kiro:spec-init-batch` が読む**唯一のコンテクスト源**になる。セッションに残っている暗黙の文脈(会話で合意した方針、捨てた選択肢、命名の由来など)は `/clear` で全て失われる前提で、**セッションを一切知らない読者が読んでも各 Spec の requirements を書けるレベル**まで書き切ること。

## Parse Arguments

- Plan name: `$1`(任意)

`$1` が空の場合は、ブレストの主題から簡潔な kebab-case 名(2–4 語)を生成して使う。既に `.kiro/multi-spec/{plan-name}.md` が存在する場合は `-2`, `-3` … を付けて一意にする。

## Preconditions

- 現在のセッションにブレスト・設計議論の文脈が存在すること。会話に分析対象となる議論が無い場合は中断し、次を案内する:

  ```
  ❌ このコマンドはブレストを行ったセッション内で実行してください。
  分割したい内容を議論してから再実行するか、単一 Spec なら /kiro:spec-init-dig を直接使ってください。
  ```

- 分割した結果 Spec が 1 つしか無い場合も中断し、`/kiro:spec-init-dig "<description>"` の直接実行を案内する(このコマンドは複数 Spec 前提)。

---

## Step 1: Analyze Session Context (silent)

現在のセッションの会話全体を振り返り、以下を洗い出す:

- **全体像** — プロジェクトの背景、最終的に何を作ろうとしているか
- **合意事項** — 会話中に決まった方針・技術選定・アーキテクチャ判断(理由込み)
- **捨てた選択肢** — 検討したが採用しなかった案とその理由(後続セッションが再検討して時間を溶かさないように)
- **未決事項** — 議論したが結論が出ていない点(後の dig インタビューで確認すべき候補)
- **分割の切れ目** — 独立して spec 化できる単位。切る基準は「requirements → design → tasks → 実装を他と独立に回せるか」

各 Spec について整理する:

- 推奨 feature 名(kebab-case、2–4 語)— 後で `/kiro:spec-init-dig` の feature 名としてそのまま使われる
- 概要(1–3 文)
- スコープ in / out
- その Spec 固有の決定済み事項・未決事項
- 他 Spec とのインターフェース(受け渡すデータ、依存する成果物)
- 依存関係と推奨実行順

## Step 2: Propose Split and Confirm

### Load AskUserQuestion

`AskUserQuestion` は deferred tool のためスキーマをロードする:

```
ToolSearch(query="select:AskUserQuestion", max_results=1)
```

ロードに失敗した場合はこの確認ステップをスキップして Step 3 へ進む(ソフトゲート)。

### Confirm

分割案をテーブル(Spec 名 / 概要 / 依存)で提示したうえで、`AskUserQuestion` で 1 回確認する:

- 質問: 「この分割でプランドキュメントを作成しますか?」
- 選択肢例: 「この分割で作成 (Recommended)」/「分割の粒度を調整したい」/「Spec の追加・削除をしたい」
- 調整の回答を得た場合は会話で調整内容を確定させてから Step 3 へ進む(調整のために必要なら AskUserQuestion を追加で使ってよい)

---

## Step 3: Write the Plan Document

`mkdir -p .kiro/multi-spec` してから `.kiro/multi-spec/{plan-name}.md` を以下の構造で書く:

```markdown
# Multi-Spec Plan: {plan-name}

- 生成日: {YYYY-MM-DD}
- 元セッション: {ブレストの主題を 1 行で}
- Status 欄は /kiro:spec-init-batch が更新する。手で編集して並び替え・追加・削除してもよい。

## 全体コンテクスト

{プロジェクト背景、最終ゴール、なぜ複数 Spec に分割するのか。
全 Spec に共通する技術的前提・アーキテクチャ方針。
セッションを知らない読者向けに省略なしで書く。}

## 共通の決定済み事項

| ID  | 決定 | 理由 |
|-----|------|------|
| G-1 | ...  | ...  |

## 検討して捨てた選択肢

| 選択肢 | 捨てた理由 |
|--------|-----------|
| ...    | ...       |

## Spec 一覧(推奨実行順)

| # | Spec | Status  | 依存 |
|---|------|---------|------|
| 1 | {kebab-name} | PENDING | -    |
| 2 | {kebab-name} | PENDING | #1   |

---

## Spec: {kebab-name}

- Status: PENDING
- Feature dir: (spec-init-batch が記入)
- 依存: {他 Spec 名 / なし}

### 概要

{1–3 文。spec-init-dig に渡す説明文の核になる}

### スコープ (in)

- ...

### スコープ (out)

- ...

### この Spec 固有の決定済み事項

| ID  | 決定 | 理由 |
|-----|------|------|
| S-1 | ...  | ...  |

### 未決事項(dig で確認すべき候補)

- ...

### 他 Spec とのインターフェース

- ...
```

`## Spec: {kebab-name}` セクションを Spec の数だけ繰り返す。

### Writing Rules

- **自己完結**が最優先。「上で話した通り」「例の方式で」のようなセッション参照は禁止。固有名詞・数値・ファイルパスは具体的に書く
- 決定済み事項には必ず理由を付ける(後続の dig インタビューが同じ質問を蒸し返さないように)
- 未決事項は「dig で聞くべき質問」の形を意識して書く
- Spec 間で重複する背景は「全体コンテクスト」に一度だけ書き、各 Spec 節からは差分のみ書く

---

## Final Summary

作成後、以下を出力する:

```
✅ Multi-spec plan created!

## Plan
- File: .kiro/multi-spec/{plan-name}.md
- Specs: {N} 件

| # | Spec | 依存 |
|---|------|------|
| ... | ... | ... |

## Next Steps
1. .kiro/multi-spec/{plan-name}.md を確認・必要なら手直し
2. /clear でセッションをクリア
3. /kiro:spec-init-batch {plan-name} を実行(各 Spec の dig インタビューに答えるため、離席せず実行すること)
```
