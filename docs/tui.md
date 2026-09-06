# TUI操作

`zt`を引数なしで実行するとTUIが起動します。`Tab`と`Shift-Tab`でIssue、Task、詳細ペインを移動し、`j`/`k`または矢印キーで項目を選択します。

## Task

| キー | 操作 |
|---|---|
| `Space` | 完了状態を切り替える |
| `a` | 選択中IssueへTaskを追加する |
| `e` | Taskタイトルを編集する |
| `J` / `K` | 兄弟内で下／上へ移動する |
| `L` / `U` | 選択中Issueへlink／unlinkする |
| `d` | 削除方針の確認を開く |
| `/` | 表示中IssueのTaskをタイトルで絞り込む。空入力で解除 |
| `s` | 確認画面でsubtreeを削除する |
| `p` | 確認画面で子を昇格して削除する |

入力画面では`Enter`で保存、`Esc`で取消します。すべての変更はCLIと同じコア検証とAtomic保存を通ります。

## IssueとProposal

Issueペインの`r`で選択RepositoryのIssueを更新します。`p`で選択IssueのProposal画面を開きます。

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

Proposal生成とIssue更新は現在同期実行です。処理中は入力を受け付けませんが、失敗時は既存Stateを維持してTUIへ戻ります。
