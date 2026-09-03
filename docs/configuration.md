# 設定と保存先

既定ではStateを`$XDG_DATA_HOME/ztodo-fx/state.json`（未設定時`~/.local/share`）、設定を`$XDG_CONFIG_HOME/ztodo-fx/config.json`（未設定時`~/.config`）へ保存します。テスト・隔離用途では`ZTODO_FX_DATA_FILE`と`ZTODO_FX_CONFIG_FILE`を両方指定できます。

両ファイルのschema versionは`1`、State上限は16 MiB、Repository上限は20件、Proposal候補は1〜20件、Taskタイトルは200 Unicode code pointまでです。書込みは一時ファイルのsync後にAtomic replaceします。

`.git`、`.env*`、credential、secret、SSH鍵、主要な認証設定は常にモデル入力から除外します。`repo exclude`で追加できます。従来のztodoデータは探索・共有・移行しません。
