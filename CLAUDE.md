# 開発メモ（unity-sdd-kit）

このリポジトリは、Unity リポジトリ向けの SDD（仕様駆動開発）ワークフロー一式の**正本**。
取り込み側リポジトリは `scripts/install.sh` で導入し、`SDD Sync` ワークフロー（`templates/consumer/sdd-sync.yml`）で追従する。

- 配布物（`.claude/` `.agents/skills/kiro-*` `.codex/` `.kiro/settings/` `AGENTS.md`）の修正は必ずこのリポジトリで行う。取り込み側で直接直すと次回の同期で消える。
- 配布物の範囲（kit が所有するパス）は `scripts/sync.sh` の `OWNED_DIRS` / `OWNED_FILES` / `SKILL_PREFIX` が正。パスを増減したら README の表も合わせて更新する。
- Claude Code 向け（`.claude/commands/kiro/` `.claude/agents/kiro/`）と Codex 向け（`.agents/skills/kiro-*/` `AGENTS.md`）は同じワークフローの 2 系統なので、片方を直したらもう片方も揃える。Unity 向けのルールは `.claude/rules/unity-sdd.md` が正で、`AGENTS.md` の「Unity Projects」節はその要約。
- `AGENTS.md` 先頭のマーカー行（`managed-by: unity-sdd-kit`）は消さない（取り込み側の同期判定に使う）。
- `scripts/` を変えたら `bash tests/sync-test.sh` を通す（シンボリックリンクのテストは Linux 前提。Windows では CI の結果で確認する）。
- Git 運用ルールと Linear 駆動の自律ワーカー（linear-worker）は [agentic-dev-harness](https://github.com/Hidano-Dev/agentic-dev-harness) の配布物で、このリポジトリには含めない。

## SDD ワークフロー

@.claude/rules/sdd-workflow.md
