# コマンドリファレンス

終了コードは成功`0`、実行・保存・外部連携エラー`1`、構文エラー`2`です。破壊的操作は対話時の小文字`y`またはサブコマンド末尾の`--yes`でのみ確定します。

```text
ztodo-fx doctor | help [command] | version
ztodo-fx repo add <owner/name> <absolute-workspace-path>
ztodo-fx repo ls
ztodo-fx repo set-workspace <owner/name> <absolute-workspace-path>
ztodo-fx repo del <owner/name> --yes
ztodo-fx repo exclude add|ls|del <owner/name> [pattern]
ztodo-fx issue ls [owner/name]
ztodo-fx issue refresh <owner/name>
ztodo-fx issue show|open <owner/name#number>
ztodo-fx task ls [--issue <owner/name#number>]
ztodo-fx task add <title...> [--issue <key>] [--parent <id>]
ztodo-fx task edit <id> <title...>
ztodo-fx task toggle <id>
ztodo-fx task move <id> <one-based-position>
ztodo-fx task reparent <id> (--parent <id>|--root)
ztodo-fx task link <id> <key>
ztodo-fx task unlink <id>
ztodo-fx task del <id> (--promote-children|--subtree) --yes
ztodo-fx task clear --yes
ztodo-fx proposal generate|show|edit <key>
ztodo-fx proposal discard|approve <key> --yes
```

Task IDは永続的です。位置はCLIでは1始まりです。toggleは子孫へ伝播しません。ツリー削除時は子の昇格か部分木全体の削除を選びます。
