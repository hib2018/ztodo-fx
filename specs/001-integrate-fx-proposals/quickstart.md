# Quickstart Validation: fx内蔵型タスク管理コア

この文書は実装後のend-to-end検証手順である。詳細なCLI規則は[CLI contract](contracts/cli.md)、
データ不変条件は[data model](data-model.md)を参照する。

## 1. Prerequisites

- macOSまたはLinux
- Zig 0.16.0
- 認証済みGitHub CLI
- 別途インストール・認証済みで、必要な非対話機能を持つfx
- 検証用GitHub Repositoryと対応するローカルWorkspace

```sh
zig version
gh auth status
fx status
```

実装された`docs/getting-started.md`が、上記ツールの導入・認証、空状態からの初期設定、除外規則を
説明していることも確認する。既存ztodoのデータは使用しない。

## 2. Isolated data paths

通常の利用者データを避けるため、検証専用directoryを作り、zt用overrideを設定する。

```sh
export ZTODO_FX_DATA_FILE="/absolute/test-area/state.json"
export ZTODO_FX_CONFIG_FILE="/absolute/test-area/config.json"
```

override名と優先順位は実装後の`docs/configuration.md`を正とする。指定先が既存ztodoの
`ztodo/tasks.json`または`ztodo/config.json`ではないことを確認する。

## 3. Build and deterministic tests

```sh
zig fmt --check build.zig src
zig build test
zig build
```

期待結果:

- 通常suiteは実GitHub、実fx、実認証、実モデル、利用者データを使わない。
- Task tree、cycle、reparent、promote、subtree delete、Proposal apply、Atomic failureが通る。
- 偽fxによるJSON envelope、権限拒否、timeout、retry、invalid outputの契約試験が通る。

## 4. Empty-start and diagnostics

```sh
./zig-out/bin/zt doctor
./zig-out/bin/zt task ls
```

期待結果:

- `doctor`はgh、fx、権限、保存先を個別に報告し、promptやcredentialを表示しない。
- 空状態は正常終了し、既存ztodo Taskを表示・移行しない。

## 5. Register Repository and Workspace

```sh
./zig-out/bin/zt repo add owner/repository /absolute/path/to/workspace
./zig-out/bin/zt repo ls
./zig-out/bin/zt issue refresh owner/repository
./zig-out/bin/zt issue ls owner/repository
```

期待結果:

- RepositoryとWorkspaceの一対一対応が表示される。
- 重複Repository、相対path、存在しないdirectory、重複Workspaceは拒否される。
- GitHub取得失敗でも以降のローカルTask操作は可能。

## 6. Manual Task tree

```sh
./zig-out/bin/zt task add "root work" --issue owner/repository#123
./zig-out/bin/zt task add "child one" --parent 1
./zig-out/bin/zt task add "child two" --parent 1
./zig-out/bin/zt task ls --issue owner/repository#123
./zig-out/bin/zt task move 3 1
./zig-out/bin/zt task toggle 1
```

期待結果:

- IssueがrootでTaskが階層表示され、兄弟順序を識別できる。
- 親完了後も子は未完了のまま。
- 子を自身の子孫へreparentする操作はStateを変更せず拒否される。

親削除の両方針を別々の検証データで確認する。

```sh
./zig-out/bin/zt task del 1 --promote-children
./zig-out/bin/zt task del 10 --subtree
```

確認で`y`以外を入力した場合は変更なし。確定時、昇格は相対順序を保ち、subtree削除は全子孫を
一括削除する。保存失敗を注入した試験では部分適用されない。

## 7. Generate and review Proposal

```sh
./zig-out/bin/zt proposal generate owner/repository#123
./zig-out/bin/zt proposal show owner/repository#123
./zig-out/bin/zt proposal edit owner/repository#123
```

期待結果:

- 明示的な`generate`だけがモデル呼び出しを開始する。
- Clipboardや別アプリへのprompt／response転送を求めない。
- fxは除外済み一時snapshotを読み、登録Workspaceを変更しない。
- 生成結果はTaskへ未反映のIssue単位Proposalとして表示される。
- 編集後に終了したProposalは同じIssueへ保存され、他IssueのProposalへ影響しない。

## 8. Duplicate warning and Atomic approval

既存Taskと完全一致する候補タイトルをProposalへ作り、承認する。

```sh
./zig-out/bin/zt proposal approve owner/repository#123
```

期待結果:

- 一致する既存Task IDと候補を表示し、追加確認前は保存しない。
- 確認後は自動merge／除外せず、Proposal tree全体を既存Taskの後へ追加する。
- Task追加とProposal削除は一つのAtomic state更新になる。
- 書込み失敗では既存TaskとProposalの両方が直前の状態を維持する。

## 9. Closed or unavailable Issue

既存Taskに紐づくIssueをCloseするか、偽ghでnot found／forbiddenを返してrefreshする。

期待結果:

- Issue nodeに`closed`、`deleted`、または`unavailable`が表示される。
- 最後に取得できたIssue情報とTask treeが保持される。
- Taskは未紐付けへ移動、非表示、削除されない。

## 10. fx safety failures

偽fxまたは隔離したテストprofileで次を検証する。

- mutation toolのallow ruleがある場合、モデル呼び出し前に拒否。
- fxが書込みまたはTerminalを要求した場合、非対話askモードで実行せず失敗。
- `final_output`空、不正JSON、Markdown fence、未知parent、cycle、21件以上の候補を拒否。
- transient failureだけ最大2回再試行し、認証・permission・validation失敗は再試行しない。
- 全失敗で既存StateとProposalを維持し、一時snapshot以外を削除しない。

## 11. Final verification

```sh
zig fmt --check build.zig src
zig build test
zig build
./zig-out/bin/zt help
./zig-out/bin/zt doctor
```

README、`docs/getting-started.md`、command reference、configuration、troubleshooting、help text、Zsh補完が
[CLI contract](contracts/cli.md)と一致することを確認する。実fx／GitHubを使うsmoke testは通常suiteと
分離し、実行有無と結果を記録する。

### 2026-09-03 実装検証記録

- Zig 0.16.0で整形、`zig build test`、`zig build`: PASS
- overrideを一時directoryへ向けたTask追加、親子追加、tree表示、toggle、move、Repository登録、一覧、doctor: PASS
- 実`gh`／実`fx`は`doctor`による実行ファイル検出のみ実施。外部Issue更新とモデル要求は外部状態・利用量へ関わるため自動smoke testでは未実行
- Homebrew配下のZig標準ライブラリ読取りが必要なため、sandbox外の許可付きでビルドした

### 2026-09-05 最終検証記録

- `zig fmt --check build.zig src`、`zig build test`、`zig build`: PASS
- 偽fx/gh、ProcessRunner、Proposal編集・承認、Issue状態遷移、200 Task・10階層、security回帰を含む全suite: PASS
- overrideを`/private/tmp`へ向け、空表示、親子Task追加、toggle、保存後tree表示、Repository登録、一覧、doctor: PASS
- 実`gh`は未認証として修復案内を表示し、実`fx`はask capabilityを確認。外部Issue更新・モデル生成は外部状態と利用量を伴うため未実行
