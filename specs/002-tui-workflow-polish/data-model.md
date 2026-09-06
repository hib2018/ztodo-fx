# Data Model: TUIワークフロー改善

## ViewState

| Field | Rule |
|---|---|
| schema_version | 初版1。未知versionは安全な既定値へ戻す |
| show_closed | 既定false |
| expanded_issues | 一意なIssueKey集合 |
| expanded_tasks | 一意なTask ID集合 |
| selected | IssueKey、Task ID、Unlinked、またはnull |

State/configとは別にAtomic保存する。存在しないIssue/Task IDは読込後に無視する。

## MenuState

`tab`（proposal/repository/issues）、各tabの選択位置、呼出元nodeをメモリ上だけに持つ。open→tab切替→actionまたはcancel→closedで遷移する。

## WrappedRow

元node、表示断片、先頭／継続、表示幅、styleを持つ一時projection。選択は元node単位、scrollは表示行単位とする。
