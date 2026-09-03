# はじめに

## 必要環境

- Zig 0.16.0
- GitHub CLI (`gh`): `gh auth login` 済み
- Vercel Labs fx: <https://github.com/vercel-labs/fx> の手順で別途導入・ログイン済み

```sh
zig build
./zig-out/bin/ztodo-fx doctor
```

## 初期設定

Repositoryごとに、絶対パスのWorkspaceを1つ登録します。

```sh
ztodo-fx repo add owner/repository /absolute/path/to/workspace
ztodo-fx repo exclude add owner/repository generated
ztodo-fx issue refresh owner/repository
ztodo-fx task ls
```

Proposal生成は明示的に開始します。fx出力は直接Taskにならず、下書きとして保存されます。

```sh
ztodo-fx proposal generate owner/repository#123
ztodo-fx proposal show owner/repository#123
ztodo-fx proposal approve owner/repository#123 --yes
```

承認前に必ず内容を確認してください。Proposal生成がWorkspaceを更新することはありません。
