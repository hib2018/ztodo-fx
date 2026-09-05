# コマンドリファレンス

終了コードは成功`0`、実行・保存・外部連携エラー`1`、構文エラー`2`です。破壊的操作は対話時の小文字`y`またはサブコマンド末尾の`--yes`でのみ確定します。

引数なしの`zt`はTUIを起動します。既存のコマンド操作はすべて`zt <command>`として利用できます。

```text
zt
zt doctor | help [command] | version
zt repo add <owner/name> <absolute-workspace-path>
zt repo ls
zt repo set-workspace <owner/name> <absolute-workspace-path>
zt repo del <owner/name> --yes
zt repo exclude add|ls|del <owner/name> [pattern]
zt issue ls [owner/name]
zt issue refresh <owner/name>
zt issue show|open <owner/name#number>
zt task ls [--issue <owner/name#number>]
zt task add <title...> [--issue <key>] [--parent <id>]
zt task edit <id> <title...>
zt task toggle <id>
zt task move <id> <one-based-position>
zt task reparent <id> (--parent <id>|--root)
zt task link <id> <key>
zt task unlink <id>
zt task del <id> (--promote-children|--subtree) --yes
zt task clear --yes
zt proposal generate|show|edit <key>
zt proposal discard|approve <key> --yes
```

Task IDは永続的です。位置はCLIでは1始まりです。toggleは子孫へ伝播しません。ツリー削除時は子の昇格か部分木全体の削除を選びます。
