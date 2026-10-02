# Unity プロジェクト規約

[目的: このリポジトリのすべての spec が従うべき、Unity 固有の決定事項を記録する]

## プロジェクト
- 構成: [マルチプロジェクト（リポジトリ直下の各ディレクトリが 1 つの Unity プロジェクト） | 単一プロジェクト]
- プロジェクト一覧: [`<ディレクトリ>` — 用途、`ProjectSettings/ProjectVersion.txt` の Unity バージョン]
- レンダーパイプライン: [URP | HDRP | Built-in]

## アセンブリ
- 機能単位で `.asmdef` を 1 つ用意し、Runtime / Editor / Tests に分ける
- 配置: `Assets/<Feature>/Runtime`、`Assets/<Feature>/Editor`、`Assets/<Feature>/Tests/EditMode`、`Assets/<Feature>/Tests/PlayMode`
- ルート名前空間: [`Company.Product.Feature`]

## テスト
- フレームワーク: Unity Test Framework（NUnit）
- ロジックは EditMode テストを優先し、PlayMode はフレーム進行・物理・入力など実行時にしか確かめられないものに限る
- Editor 実行ファイル: [`ProjectVersion.txt` のバージョンに固定したパス（指定がある場合）]
- テストコマンド: [リポジトリ固有のコマンド | `unity test <プロジェクトディレクトリ> --mode EditMode`（Unity CLI） | Unity Test Runner の batchmode 実行]
- MonoBehaviour は薄く保ち、ロジックは素の C# クラスに置いて EditMode でテストできるようにする

## アセットとシリアライズ
- シーン・プレハブ・アセットの YAML を手で編集しない。Editor 経由（Unity CLI の `unity command`）で変更するか、コードから生成する
- `.meta` ファイルは Unity に生成させる。手で書く場合、GUID は必ずランダムな 32 桁 hex を新たに生成する
- パッケージを変更したら `Packages/packages-lock.json` をコミットする。`Library/`、`Temp/`、`Logs/`、`UserSettings/` はコミットしない

## パッケージ
- サードパーティのレジストリ: [使用している scopedRegistries]
- パッケージ追加の方針: [例: 公式レジストリを優先、バージョンを固定する]

---
_spec が守るべき決定事項に絞って書く。ツールの使い方の詳細は unity-cli skill に任せる。_
