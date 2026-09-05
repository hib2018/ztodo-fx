# はじめに

## 必要環境

- Zig 0.16.0
- GitHub CLI (`gh`): `gh auth login` 済み
- Vercel Labs fx: <https://github.com/vercel-labs/fx> の手順で別途導入・ログイン済み

```sh
zig build
./zig-out/bin/zt doctor
```

## 初期設定

Repositoryごとに、絶対パスのWorkspaceを1つ登録します。

```sh
zt repo add owner/repository /absolute/path/to/workspace
zt repo exclude add owner/repository generated
zt issue refresh owner/repository
zt task ls
```

初期設定後は、引数なしでTUIを起動できます。

```sh
zt
```

初期TUIでは`j`/`k`または矢印キーでTaskを選択し、`Space`で完了状態を切り替え、`q`で終了します。

Proposal生成は明示的に開始します。fx出力は直接Taskにならず、下書きとして保存されます。

```sh
zt proposal generate owner/repository#123
zt proposal show owner/repository#123
zt proposal approve owner/repository#123 --yes
```

承認前に必ず内容を確認してください。Proposal生成がWorkspaceを更新することはありません。
