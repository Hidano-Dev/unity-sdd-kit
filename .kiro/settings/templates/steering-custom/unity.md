# Unity Project Standards

[Purpose: record Unity-specific decisions that every spec in this repository must follow]

## Projects
- Layout: [multi-project (one Unity project per top-level directory) | single project]
- Projects: [`<dir>` — purpose, Unity version from `ProjectSettings/ProjectVersion.txt`]
- Render pipeline: [URP | HDRP | Built-in]

## Assemblies
- One `.asmdef` per feature area; Runtime / Editor / Tests split
- Placement: `Assets/<Feature>/Runtime`, `Assets/<Feature>/Editor`, `Assets/<Feature>/Tests/EditMode`, `Assets/<Feature>/Tests/PlayMode`
- Root namespace: [`Company.Product.Feature`]

## Testing
- Framework: Unity Test Framework (NUnit)
- Prefer EditMode tests for logic; PlayMode only for frame / physics / input behavior
- Run with Unity CLI: `unity test <project-dir> --mode EditMode` (and `--mode PlayMode`)
- Keep MonoBehaviours thin; put logic in plain C# classes so it is testable in EditMode

## Assets & Serialization
- Do not hand-edit scene / prefab / asset YAML; change them through the Editor (Unity CLI `unity command`) or generate from code
- `.meta` files: let Unity generate them; hand-written GUIDs must be fresh random 32-hex values
- Commit `Packages/packages-lock.json` when packages change; never commit `Library/`, `Temp/`, `Logs/`, `UserSettings/`

## Packages
- Third-party registries: [scopedRegistries in use]
- Adding a package: [policy — e.g. official registry first, version pinning]

---
_Focus on decisions that specs must respect. Tool usage details live in the unity-cli skill._
