# Unity プロジェクトでの SDD

unity-sdd-kit が配布する、Unity プロジェクト向けの追加ルール。`sdd-workflow.md` から import される。
対象リポジトリが Unity プロジェクトを含まない場合、この節は適用しない。

## 前提: リポジトリ構成とツール

- [unity-project-template](https://github.com/Hidano-Dev/unity-project-template) から生成したリポジトリは**マルチプロジェクト構成**（リポジトリ直下の各ディレクトリが独立した Unity プロジェクト。`ProjectSettings/ProjectVersion.txt` を持つものがプロジェクト）。リポジトリ直下に `Assets/` が 1 つだけある単一プロジェクト構成もあり得るので、最初に実際の構成を確認する。
- Unity Editor の起動・操作・テスト・ビルドは **Unity CLI（`unity` コマンド）** で行う。使い方は `unity-cli` skill（`.claude/skills/unity-cli/`）を参照。CLI が Editor を操作するには対象プロジェクトに `com.unity.pipeline` パッケージが必要。

## Spec の書き方

- requirements / design / tasks には**対象プロジェクトのディレクトリ**を明記する（複数プロジェクトにまたがる spec は、プロジェクトごとにタスクを分ける）。
- design では、ランタイム / Editor 拡張 / テストのアセンブリ境界（`.asmdef`）と配置先（`Assets/<...>/Runtime`、`Editor`、`Tests/EditMode`、`Tests/PlayMode` など）を決める。
- tasks では、各実装タスクに対応するテスト（Unity Test Framework。ロジックは EditMode を優先し、PlayMode はフレーム進行・物理・入力など実行時にしか確かめられないものに限る）を含める。
- steering（`/kiro:steering`）では `tech.md` に Unity バージョン（`ProjectVersion.txt`）、レンダーパイプライン、主要パッケージ、テスト方針を、`structure.md` にプロジェクトディレクトリとアセンブリ構成を記録する。

## 実装・検証（spec-impl / spec-run / validate-impl）

- **コンパイル確認とテストは Unity CLI で行う**。成功を主張する前に、少なくとも対象プロジェクトの EditMode テストを実行して結果を確認する:

  ```
  unity test <プロジェクトディレクトリ> --mode EditMode --output <出力先>/editmode-results.xml
  ```

  PlayMode のテストがあるタスクは `--mode PlayMode` も実行する。`SMOKE_COMMANDS` / 検証コマンドを決める場面では上記を既定とする。
- 同じプロジェクトを開いている Editor があると batch 起動の `unity test` はプロジェクトロックで失敗する。`unity status` で接続中の Editor を確認し、開いているなら閉じてから実行するか、Editor 側のコマンド（`unity command`）で代替する。
- `unity status` / `unity command` が Editor に繋がらないときは、コンパイルエラーで Safe Mode になっていないかを `unity pipeline list` で確認し、エラーを直す。ファイルの手編集に逃げない。
- CLI から Editor を GUI 付きで起動する場合は `-automated` を渡す（`unity open <プロジェクトディレクトリ> --args "-automated"`）。ブロッキングダイアログで処理が止まらなくなる。

## Unity アセットの扱い

- シーン（`.unity`）・プレハブ（`.prefab`）・ScriptableObject（`.asset`）の YAML を手で編集しない。Editor が使えるなら Unity CLI 経由（`unity command eval '<C#>'` や Editor コマンド）で変更し、保存させる。使えない場合はコードからの生成手順をタスクに含め、手編集が避けられない場合はその旨を報告する。
- 新規ファイルの `.meta` は、可能なら Unity に生成させる。手で書く場合、GUID は必ずランダムな 32 桁 hex を新たに生成して使う（連続・規則的なパターンや既存 GUID の流用は禁止。プロジェクト間で衝突して片方が無視される）。
- `Library/` `Temp/` `Logs/` `UserSettings/` などの生成物はコミットしない。`Packages/packages-lock.json` はパッケージ変更時に更新してコミットする。
