# TUI操作

`zt`を引数なしで実行するとTUIが起動します。画面は左右半分のIssue・TaskツリーとDetailsペインで構成されます。

## 基本操作

| キー | 操作 |
|---|---|
| `j` / `k`、矢印キー | 選択またはDetailsを上下へ移動 |
| `Tab` / `Shift-Tab` | ペインを移動 |
| `Enter` | Issue、Unlinked、子を持つTaskを展開／折り畳み |
| `g` / `G` | Detailsの先頭／末尾へ移動 |
| `/` | Taskをタイトルで絞り込み。空入力で解除 |
| `m` | 管理メニューを開く |
| `?` | ヘルプを開く |
| `q` | 終了 |

Issueを親、そのTaskと子Taskを子孫として罫線付きで表示します。Issueに紐付かないTaskは`Unlinked`配下です。長いタイトルとDetailsはペイン内で折り返されます。マウスクリックによる選択とホイール移動にも対応しています。

Closed Issueは既定で非表示です。展開状態、Closed表示設定、最後の選択対象は操作ごとに保存され、次回起動時に復元されます。

## 管理メニュー

`m`で開き、`Tab`／`Shift-Tab`でProposal、Repositories、Issuesタブを切り替えます。`j`／`k`で項目を選び、`Enter`で実行、`Esc`で取り消します。選択中タブは反転色、選択項目は`▶`で表示されます。

## Task

| キー | 操作 |
|---|---|
| `Enter` | Issue、Unlinked、子を持つTaskを展開／折り畳みする |
| `Space` | 完了状態を切り替える |
| `a` | 選択中IssueへTaskを追加する |
| `e` | Taskタイトルを編集する |
| `R` | 移動先を指定する。`root`、`unlinked`、親Task ID、`owner/repo#番号`を入力 |
| `J` / `K` | 兄弟内で下／上へ移動する |
| `L` / `U` | 選択中Issueへlink／unlinkする |
| `d` | 削除方針の確認を開く |
| `C` | 全Taskの件数を確認して消去する |
| `/` | 表示中IssueのTaskをタイトルで絞り込む。空入力で解除 |
| `s` | 確認画面でsubtreeを削除する |
| `p` | 確認画面で子を昇格して削除する |

入力画面では`Enter`で保存、`Esc`で取消します。すべての変更はCLIと同じコア検証とAtomic保存を通ります。

## GitHub Issue

Issuesタブから次の操作を実行できます。

| 操作 | 対象と流れ |
|---|---|
| 詳細 | 選択中IssueのDetailsへ移動 |
| 一覧更新 | 選択中IssueのRepositoryを再取得 |
| GitHubで開く | 選択中Issueをブラウザで表示 |
| 編集 | タイトルと本文を入力し、確認後に更新 |
| 作成 | 登録済みRepository、タイトル、本文を選択・入力し、確認後に作成 |
| Close／Reopen | 選択中Issueの状態に応じ、確認後に切り替え |
| Closed表示切替 | Closed Issueの表示・非表示を切り替え |

GitHub操作後はRepositoryを再取得し、ローカルsnapshotへ同期します。GitHub側の変更後に再同期またはローカル保存だけが失敗した場合は、リモートが変更済みであることと再同期方法を画面へ表示します。

## Proposal

ツリー上のIssueまたは配下Taskを選択し、管理メニューのProposalタブを開きます。

| キー | Proposal操作 |
|---|---|
| `g` | fxでDraftを生成する |
| `a` / `e` / `d` | 候補を追加／編集／削除する |
| `J` / `K` | 候補を並べ替える |
| `R` | 親candidate IDを変更する。`root`でrootへ戻す |
| `A` | Proposalを確認後に承認する |
| `D` | Proposalを確認後に破棄する |
| `Esc` | Task画面へ戻る |

既存Taskと同一タイトルの候補がある場合、承認時に追加確認が入ります。既存Draftがある状態で`g`を押しても上書きせず、先に既存Draftを確認または破棄する必要があります。

Proposal生成はバックグラウンドで実行され、画面に進捗状態を表示します。`Esc`でFutureとfx子プロセスへキャンセルを伝播し、既存Stateを維持してProposal画面へ戻ります。Issue更新は短時間処理として現在は同期実行です。

## Repository設定

通常画面で`m`を押し、RepositoriesタブからRepository設定画面を開きます。`a`で`owner/repo /absolute/workspace`を入力して追加し、`e`で選択RepositoryのWorkspaceを変更します。`d`は確認後に設定を削除します。設定変更もAtomic保存され、保存失敗時は直前の設定へ戻ります。
