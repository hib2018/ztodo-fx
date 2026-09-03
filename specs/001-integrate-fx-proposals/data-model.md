# Data Model: fx内蔵型タスク管理コア

## Storage boundaries

| File | Ownership | Atomic unit | Default namespace |
|---|---|---|---|
| `state.json` | Task、IssueSnapshot、Proposal | ファイル全体 | XDG data `ztodo-fx` |
| `config.json` | RepositoryConfig、除外規則 | ファイル全体 | XDG config `ztodo-fx` |

両ファイルは独立して読み込める。`state.json`の操作はGitHub・fx設定が壊れていても利用可能とする。
既存ztodoの`ztodo/tasks.json`、`proposal.json`、`config.json`は探索も移行もしない。

## StateRoot

| Field | Type | Rules |
|---|---|---|
| `schema_version` | `u32` | 初版は`1`。未知の値は拒否 |
| `next_task_id` | `u64` | 1以上、全Task IDより大きい |
| `tasks` | `[]Task` | ID一意、最大は16 MiB file limitで制約 |
| `issues` | `[]IssueSnapshot` | `IssueKey`一意 |
| `proposals` | `[]Proposal` | `IssueKey`一意、Issueごとに最大1件 |

### Whole-state invariants

- Taskの`parent_id`は同じ`tasks`内に存在し、自身を参照しない。
- 親参照グラフに循環がない。
- 親子の`issue_key`は一致する。
- 同じ親とIssue rootに属するTaskの`position`は0から始まる連続値で重複しない。
- `issue_key`を持つTaskとProposalには対応する`IssueSnapshot`が存在する。
- 全不変条件を検証してからメモリ上の新状態を採用し、全体をAtomic保存する。

## RepositoryConfig

| Field | Type | Rules |
|---|---|---|
| `repository` | string | `owner/name`形式、設定内で一意、最大200 code point |
| `workspace_path` | string | 絶対パス、既存directory、Repositoryごとに1件 |
| `exclude_patterns` | `[]string` | UTF-8、空不可、最大64件。Workspace外を対象にできない |
| `registration_order` | `u32` | Repository一覧の安定順序 |

設定全体はRepository最大20件。登録時にWorkspaceの存在、directory種別、絶対パスを検証する。
同じWorkspaceを複数Repositoryへ対応付ける操作は誤生成を避けるため拒否する。

## IssueKey

複合識別子`repository + issue_number`。

| Component | Type | Rules |
|---|---|---|
| `repository` | string | 登録時と同じcanonical `owner/name` |
| `issue_number` | `u64` | 1以上 |

文字列表現はCLIとProposal contractで`owner/name#123`を使う。永続JSONでは曖昧なsplitを避けるため
構造体として保存する。

## IssueSnapshot

| Field | Type | Rules |
|---|---|---|
| `key` | `IssueKey` | 状態内で一意 |
| `title` | string | UTF-8、最大256 code point |
| `body` | string | UTF-8、取得上限内 |
| `status` | enum | `open`, `closed`, `deleted`, `unavailable` |
| `last_fetched_at` | timestamp/null | GitHubから成功取得した時刻 |
| `last_error` | enum/null | `not_found`, `forbidden`, `network`, `unknown`。秘密情報を含めない |

### State transitions

```text
unseen -> open
open -> open | closed | deleted | unavailable
closed -> open | closed | deleted | unavailable
deleted/unavailable -> open | closed | deleted | unavailable
```

取得失敗時は最後のtitle/bodyを保持し、`status`と`last_error`だけを新状態へ更新する。Issue nodeを
消さず、Taskの`issue_key`も変更しない。

## Task

| Field | Type | Rules |
|---|---|---|
| `id` | `u64` | 不変、1以上、状態内で一意 |
| `title` | string | trim後非空、UTF-8、制御文字なし、最大200 code point |
| `status` | enum | `todo`, `done` |
| `issue_key` | `IssueKey`/null | nullは未紐付けroot |
| `parent_id` | `u64`/null | 存在するTask、同じ`issue_key`、循環不可 |
| `position` | `u32` | 同じ親直下で0始まりの連続値 |

### Operations

- **Add**: 対象親の末尾へ追加し、`next_task_id`を単調増加。
- **Move within siblings**: 対象範囲の`position`を再採番。
- **Reparent**: 部分ツリー全体の`issue_key`を新しい親またはrootへ合わせ、循環検査後に適用。
- **Toggle completion**: 対象Taskだけを変更。子孫へ伝播しない。
- **Delete with promote**: 親を除き、直下の子を親の位置から相対順序を保って挿入。子孫構造は維持。
- **Delete subtree**: 対象と全子孫を列挙し、確認対象を固定してから一括削除。
- **Clear**: 全Taskを確認後に削除し、`next_task_id`を1へ戻す。IssueSnapshotとProposalは別途
  明示されない限り保持。

## Proposal

| Field | Type | Rules |
|---|---|---|
| `issue_key` | `IssueKey` | Proposal配列内で一意 |
| `issue_title` | string | 生成時snapshotとの照合対象 |
| `summary` | string | 非空、最大2000 code point |
| `completion_criteria` | `[]string` | 最大20件、各500 code point |
| `candidates` | `[]CandidateTask` | 1〜20件、ID一意、循環不可 |
| `excluded` | `[]string` | 最大20件、各500 code point |
| `notes` | `[]string` | 最大20件、各500 code point |
| `generation` | `GenerationMetadata` | provider/model/session本文やpromptは保存しない |
| `updated_at` | timestamp | 下書き保存時刻 |

同じIssueへ新規生成する場合、既存Proposalの上書き対象と差分を表示し、明示確認後にだけ置換する。

## CandidateTask

| Field | Type | Rules |
|---|---|---|
| `candidate_id` | string | Proposal内で一意な短いopaque ID |
| `title` | string | Task titleと同じ検証 |
| `parent_candidate_id` | string/null | Proposal内に存在、循環不可 |
| `position` | `u32` | 同じ親直下で0始まりの連続値 |

Proposal内の候補同士でtrim後タイトルが完全一致する場合は無効。既存Taskとの完全一致は
`DuplicateWarning`を生成するが、追加確認後の承認を許可する。

## GenerationMetadata

| Field | Type | Rules |
|---|---|---|
| `generated_at` | timestamp | 成功応答を受理した時刻 |
| `fx_version` | string | 診断用。秘密を含めない |
| `attempt_count` | `u8` | 1〜3（初回＋再試行最大2回） |

prompt全文、fx `output`、`final_output`、認証情報、session IDは永続化しない。

## GenerationSession

メモリ上だけに存在する一回の生成処理。

```text
idle
  -> preparing_snapshot
  -> checking_permissions
  -> running
  -> validating
  -> saved
```

任意の中間状態から`failed`または`cancelled`へ遷移できる。`saved`前は`StateRoot`を変更しない。
一時的な通信・provider障害だけ`running`へ最大2回戻れる。

## DuplicateWarning

| Field | Type | Rules |
|---|---|---|
| `candidate_id` | string | Proposal候補を参照 |
| `existing_task_id` | `u64` | 同じIssueの既存Taskを参照 |
| `title` | string | trim後の完全一致タイトル |

警告は承認直前に最新Stateから再計算する。確認対象のProposalまたはStateが変わった場合、古い確認を
無効化して再表示する。

## Transaction rules

1. 全操作は現在Stateをcloneした作業コピーへ適用する。
2. 作業コピー全体の不変条件を検証する。
3. JSON全体を一時ファイルへ書き、flushとsyncを行う。
4. Atomic replaceが成功した後だけ、メモリ上の現在Stateを作業コピーへ切り替える。
5. Proposal承認はTask追加と対象Proposal削除を同じ作業コピーで行う。
6. 失敗時は一時ファイルを破棄し、現在Stateと保存済みファイルを維持する。
