# unity-sdd-kit

Claude Code / Codex で回す **SDD（Spec-Driven Development、Kiro 方式の仕様駆動開発）ワークフロー**を、Unity リポジトリへ導入・同期するためのキットです。SDD ワークフロー一式の正本で、Unity プロジェクト向けの追加ルール（Unity CLI による検証、マルチプロジェクト構成、アセットの扱い）を同梱しています。

> 旧 `unity-sdd-template`。Unity プロジェクトを生成・保守する部分は [unity-project-template](https://github.com/Hidano-Dev/unity-project-template) に、SDD 一式は [agentic-dev-harness](https://github.com/Hidano-Dev/agentic-dev-harness) からこのリポジトリに（どちらも履歴ごと）移しました。

## リポジトリの役割分担

| リポジトリ | 役割 |
|---|---|
| [unity-project-template](https://github.com/Hidano-Dev/unity-project-template) | Unity リポジトリを生成するテンプレート（設定済みプロジェクト、Unity バージョン管理、Unity CLI と `unity-cli` skill）。SDD には依存しない |
| **unity-sdd-kit**（本リポジトリ） | SDD ワークフロー一式の正本。既存リポジトリに後から導入し、同期ワークフローで追従させる |
| [agentic-dev-harness](https://github.com/Hidano-Dev/agentic-dev-harness) | Linear 駆動の自律ワーカー（linear-worker）、Git 運用ルール、実行リポジトリの台帳、オンボーディング。SDD は含まない |

典型的な組み合わせ: unity-project-template でリポジトリを生成 → 本キットで SDD を導入 →（自律運用したい場合）agentic-dev-harness の Onboard Repository で linear-worker を導入。

## 何が入っているか（配布物）

取り込み側に配布し、同期で上書きするのは次のパスだけです（定義は `scripts/sync.sh`）。

| パス | 内容 |
|---|---|
| `.claude/commands/kiro/` | `/kiro:*` コマンド（spec-init / requirements / design / tasks / impl / run / validate-* ほか） |
| `.claude/agents/kiro/` | 各コマンドが使う Claude サブエージェント |
| `.claude/skills/dev-orchestrator/` | spec-init → 実装 → PR を承認ゲート付きで自動オーケストレーションする skill |
| `.claude/rules/sdd-workflow.md` | SDD の進め方（取り込み側の CLAUDE.md から `@` import される入口） |
| `.claude/rules/unity-sdd.md` | Unity プロジェクト向けの追加ルール（sdd-workflow.md から import） |
| `.agents/skills/kiro-*/` | Codex 用 SDD skill |
| `.codex/agents/spec-reviewer.toml` | Codex 用エージェント定義 |
| `.kiro/settings/` | spec / steering のテンプレートと生成ルール（steering-custom に `unity.md` を追加） |
| `AGENTS.md` | Codex 用プロジェクトメモリ（先頭にマーカー行あり。Unity 節を含む） |

同期の扱い:

- 上の**ディレクトリは kit と同じ内容に揃えます**（kit 側で削除したファイルは取り込み側からも消えます）。`.agents/skills/` は `kiro-` で始まる skill だけが対象で、`unity-cli` などほかの skill には触れません。
- `.kiro/specs/` `.kiro/steering/` `.kiro/orchestration/`、自作の skill、agentic-dev-harness の配布物（`.claude/skills/linear-worker/` `.claude/rules/git-workflow.md`）には触れません。
- `AGENTS.md` は先頭にマーカー（`managed-by: unity-sdd-kit`。移行のため旧 `managed-by: agentic-dev-harness` も対象）があるときだけ上書きします。プロジェクト固有の追記をしたら、マーカー行を消すと同期の対象から外れます。
- ルート `CLAUDE.md` には `@.claude/rules/sdd-workflow.md` の 1 行が無ければ追記します（ファイルが無ければ作ります）。それ以外の内容には触れません。
- 同期先にシンボリックリンクや submodule があると、何も書き換えずに中止します。

### Unity 向けの追加内容

`unity-sdd.md`（Claude）と `AGENTS.md` の「Unity Projects」節（Codex）で、次のことを定めています。

- マルチプロジェクト構成を前提に、spec に対象プロジェクトのディレクトリを明記する。
- 成功を主張する前に、**Unity CLI で EditMode（必要なら PlayMode）テストを実行する**（`unity test <プロジェクトディレクトリ> --mode EditMode`）。`SMOKE_COMMANDS` の既定もこれにする。
- シーン・プレハブ・アセットの YAML を手で編集しない（Editor が使えるなら Unity CLI 経由で変更する）。`.meta` の GUID は必ずランダムに生成する。
- steering-custom の `unity.md` テンプレートで、プロジェクト構成・アセンブリ・テスト方針・アセットの扱いを記録する。

Unity CLI 本体と `unity-cli` skill は unity-project-template が提供します（このキットには含みません）。

## 導入

取り込み側リポジトリのルートで実行します（Windows は Git Bash で）。

```bash
curl -fsSL https://raw.githubusercontent.com/Hidano-Dev/unity-sdd-kit/main/scripts/install.sh | bash
```

本リポジトリを clone 済みなら `bash <kit>/scripts/install.sh <取り込み側のルート>` でも同じです。何度実行しても同じ結果になります。

1. 配布物をコピーし、`CLAUDE.md` に import 行を追加します。
2. 同期ワークフロー `.github/workflows/sdd-sync.yml` を配置します（既にあれば触りません）。
3. コミットはしないので、`git status` で差分を確認してからコミット・push します。

## 追従（SDD Sync）

取り込み側の Actions タブ →「**SDD Sync**」→「Run workflow」で、本リポジトリの最新 main を取り込み直します。差分がある時だけ `chore: sync unity-sdd-kit assets` としてコミットされます。定期的に追従したい場合は、ワークフロー内でコメントアウトされている `schedule` を有効にします。

同期の中身は本リポジトリの `scripts/sync.sh` にあり、ワークフローは kit を clone してそれを呼ぶだけです。そのため、同期ロジックを直しても取り込み側のワークフローファイルを更新する必要はありません。

## 移行（既存リポジトリ）

### unity-sdd-template から生成したリポジトリ

生成先には `.github/workflows/orchestration-sync.yml` があり、agentic-dev-harness から SDD 一式を取り込んでいました。harness からは SDD が無くなるので、次のようにします。

1. 本キットの `install.sh` を実行し、`sdd-sync.yml` を配置して SDD を本キットの版に揃える（`AGENTS.md` の旧マーカーはそのまま引き継がれる）。
2. `orchestration-sync.yml` は削除する。linear-worker を使っている場合は、代わりに agentic-dev-harness の `harness-sync.yml` を配置する（手順は agentic-dev-harness の docs/changelog.md を参照）。

### agentic-dev-harness の Harness Sync で SDD を取り込んでいたリポジトリ

1. 本キットの `install.sh` を実行する（SDD の取り込み元が本キットに切り替わる）。
2. `harness-sync.yml` は agentic-dev-harness の新版に差し替える（新版は linear-worker と Git 運用ルールだけを同期する）。CLAUDE.md には harness 側の import 行（`@.claude/rules/git-workflow.md`）も必要。

移行前に harness から取り込んだ SDD のファイルは、そのまま本キットの版で上書きされます。harness 側で削除されたファイルの残骸も、所有ディレクトリを揃える際に消えます。

## メンテナンス

- 配布物の修正はこのリポジトリで行います。Claude 向け（`.claude/`）と Codex 向け（`.agents/skills/` `AGENTS.md`）は同じワークフローの 2 系統なので、両方を揃えます。
- `scripts/` を変えたら `bash tests/sync-test.sh` を通します（CI の Test ワークフローでも実行されます）。
- このリポジトリには秘匿情報を置かないでください（public で、取り込み側の Actions がトークンなしで clone します）。
