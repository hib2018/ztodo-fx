# zt

GitHub Issueをルート、Taskを子孫として管理し、Vercel Labs fxによるProposal作成を人間の確認・編集・承認フローへ組み込むZig製タスク管理ツールです。`zt`でTUI、`zt task`などのサブコマンドで同じUI非依存コアを操作できます。

必要環境はZig 0.16.0、認証済みGitHub CLI、別途導入・認証済みの[fx](https://github.com/vercel-labs/fx)です。

```sh
zig build
./zig-out/bin/zt doctor
./zig-out/bin/zt repo add owner/repo /absolute/workspace
./zig-out/bin/zt
```

TUIはIssueを親とするTaskツリーと詳細の2ペイン表示です。`j`/`k`または矢印キーで項目を選択し、`Enter`で展開・折り畳み、`Space`でTaskの完了状態を切り替え、`q`で終了します。

- [導入と初期設定](docs/getting-started.md)
- [コマンド一覧](docs/command-reference.md)
- [TUI操作](docs/tui.md)
- [保存先・除外設定](docs/configuration.md)
- [トラブルシューティング](docs/troubleshooting.md)
