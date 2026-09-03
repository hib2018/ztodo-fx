# ztodo-fx

GitHub Issueをルート、Taskを子孫として管理し、Vercel Labs fxによるProposal作成を人間の確認・編集・承認フローへ組み込むZig CLIです。TUIは今後の対象で、現在はUI非依存のコマンドコアを提供します。

必要環境はZig 0.16.0、認証済みGitHub CLI、別途導入・認証済みの[fx](https://github.com/vercel-labs/fx)です。

```sh
zig build
./zig-out/bin/ztodo-fx doctor
./zig-out/bin/ztodo-fx repo add owner/repo /absolute/workspace
```

- [導入と初期設定](docs/getting-started.md)
- [コマンド一覧](docs/command-reference.md)
- [保存先・除外設定](docs/configuration.md)
- [トラブルシューティング](docs/troubleshooting.md)
