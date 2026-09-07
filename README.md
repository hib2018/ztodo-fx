# zt

GitHub Issueを親、Taskを子孫として管理するZig製の開発用タスク管理ツールです。Vercel Labs [fx](https://github.com/vercel-labs/fx)が作成したProposalを、人間が確認・編集・承認してTaskへ反映できます。

`zt`はTUIを起動し、`zt task`などのサブコマンドは同じUI非依存コアを操作します。

## クイックスタート

必要環境はZig 0.16.0、認証済みGitHub CLI、導入・認証済みのfxです。

```sh
zig build
./zig-out/bin/zt doctor
./zig-out/bin/zt repo add owner/repo /absolute/workspace
./zig-out/bin/zt
```

TUIではIssue・Taskツリーと詳細を左右に表示します。`Enter`でツリーを展開し、`m`からProposal、Repository、GitHub Issueを管理できます。Closed Issueの表示、ツリーの展開状態、最後の選択対象は次回起動時に復元されます。

## ドキュメント

- [導入と初期設定](docs/getting-started.md)
- [コマンド一覧](docs/command-reference.md)
- [TUI操作](docs/tui.md)
- [保存先・除外設定](docs/configuration.md)
- [トラブルシューティング](docs/troubleshooting.md)
