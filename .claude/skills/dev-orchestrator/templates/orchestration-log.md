# Orchestration Log: {{FEATURE_NAME}}

- Started: {{TIMESTAMP}}
- Mode: {{new | resume}}
- Options: {{--stop-after 等、指定があれば}}
- Environment: {{local | degraded (claude -p only) | cloud (impl skipped)}}

<!-- 以下、各フェーズ完了ごとに追記する。既存エントリは書き換えない -->

## Phase {{N}}: {{phase-name}} — {{TIMESTAMP}}

- Command: `{{実行したコマンド}}`
- Result: {{SubAgent サマリ 1〜3行}}
- Reviewer: {{validate コマンドと結果 / なし}}
- Gate {{A|B|C|D}}: {{AUTO-APPROVED | ESCALATED | REJECTED}}
  - Rationale: {{どの基準に照らして何を確認したか（1〜3行）}}
  - Escalation: {{ESCALATED の場合のみ: 質問 / 選択肢 / ユーザーの回答}}
  - Retry: {{差し戻し再実行した場合: 回数と理由}}
