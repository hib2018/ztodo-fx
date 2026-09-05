# トラブルシューティング

- `gh`がない: GitHub CLIを導入し、`gh auth login`を実行します。
- `fx`がない／未認証: fxを別途導入し、そのバージョンに対応するloginを実行します。
- Unsafe permission: fxの実効権限からTerminal、write、upload、Workspace外pathのallow ruleを取り消します。
- timeout/provider error: 接続を確認して再実行します。自動再試行は一時障害だけ最大2回です。
- invalid envelope/Proposal: fxとztのversionを確認し、Proposalを再生成します。無効出力は保存されません。
- State破損: エラーに表示された`state.json`を退避し、バックアップから復旧します。検証失敗時にファイルは上書きされません。
- Workspace unavailable: `repo set-workspace owner/name /absolute/path`で更新します。

`zt doctor`はモデル要求を送らず、pathと外部CLIの状態を表示します。prompt、Issue本文、fx response、credentialは通常診断へ出しません。
