# Quickstart Validation: TUIワークフロー改善

```sh
zig fmt --check build.zig src
zig build test
zig build
./zig-out/bin/zt
```

長い日本語タイトル、10階層Task、長文Issue、Open/Closed/deleted Issueを含む隔離stateを使用する。枠内title、幅内折り返し、表示行scroll、`m`の3 tab、Issue操作、Closed切替、Task追加先、Repository削除影響、再起動後のview復元を確認する。実GitHubを開く試験は通常suiteから分離する。
