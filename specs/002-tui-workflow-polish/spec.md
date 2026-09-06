# Feature Specification: TUIワークフロー改善

**Feature Branch**: `main`

**Created**: 2026-09-06

**Status**: Draft

**Input**: TUIの表示崩れを防ぎ、日常操作と管理操作を分離し、Issue操作と表示制御をアプリ内で完結させる。

## User Scenarios & Testing *(mandatory)*

### User Story 1 - 読みやすいTaskツリーと詳細表示 (Priority: P1)

利用者は端末幅や文字列の長さにかかわらず、Issue・TaskツリーとDetailsを欠落やはみ出しなく読み、選択対象を見失わずに操作する。

**Why this priority**: 表示が崩れるとすべての操作の対象を誤認するため。

**Independent Test**: 長い日本語・英数字タイトル、深い階層、長文Issue本文を含む状態を複数の端末幅で表示し、全内容へ移動できることを確認する。

**Acceptance Scenarios**:

1. **Given** ペイン幅より長い行がある、**When** TUIを表示する、**Then** 内容はペイン境界内で折り返され、隣のペインや枠へはみ出さない。
2. **Given** 2つのペインが表示される、**When** 画面を見る、**Then** 各ペイン名は上枠内に表示され、本文の1行を消費しない。
3. **Given** 長いDetailsがある、**When** 利用者が上下または末尾へ移動する、**Then** 折り返し後の表示行を基準に全文を閲覧できる。
4. **Given** Issue一覧が更新または並べ替えられる、**When** 再描画する、**Then** 展開状態は別Issueへ誤って引き継がれない。

---

### User Story 2 - 管理操作をメニューから実行する (Priority: P1)

利用者は日常的なTask操作をツリー上で続けつつ、Proposal、Repository、Issueの管理操作を一つのポップアップメニューから選択する。

**Why this priority**: 多数のショートカットを暗記せず、操作領域と実行内容を発見可能にするため。

**Independent Test**: 通常画面からメニューを開き、各タブを切り替え、操作を実行または取り消して元の選択へ戻れることを確認する。

**Acceptance Scenarios**:

1. **Given** 通常画面である、**When** メニューキーを押す、**Then** Proposal・Repository・Issueのタブを持つポップアップが開く。
2. **Given** メニューが開いている、**When** タブと項目を選択する、**Then** 選択対象に対して利用可能な操作だけが実行できる。
3. **Given** メニューまたはその配下の操作中である、**When** 取り消す、**Then** データを変更せず元のツリー選択へ戻る。
4. **Given** Proposal生成・承認や削除操作を選んだ、**When** 実行する、**Then** 既存の確認・安全性・Atomic保存規則が維持される。

---

### User Story 3 - IssueをTUI内で管理する (Priority: P2)

利用者はIssueの更新、詳細確認、ブラウザ表示、Closed Issue表示切替をTUI内から実行する。

**Why this priority**: Issue起点の作業でCLIへ戻る往復をなくすため。

**Independent Test**: OpenとClosedの保存済みIssueを用意し、既定表示、表示切替、更新、詳細、ブラウザ表示を確認する。

**Acceptance Scenarios**:

1. **Given** OpenとClosedのIssueがある、**When** TUIを起動する、**Then** Open Issueだけが表示され、Closed Issue配下のTaskは削除・移動されない。
2. **Given** IssueメニューでClosed表示を有効にする、**When** ツリーへ戻る、**Then** Closed Issueが状態付きで表示され、再度無効にできる。
3. **Given** Issueまたは配下Taskを選択している、**When** 更新を実行する、**Then** 対応RepositoryのIssueが更新され、失敗時も保存済みTaskを操作できる。
4. **Given** Issueを選択している、**When** ブラウザ表示を実行する、**Then** 対応するGitHub Issueが開く。

---

### User Story 4 - Task操作の細部を完成する (Priority: P2)

利用者は選択位置に応じたTask追加、影響の分かる削除、安定した展開状態を利用できる。

**Why this priority**: 誤った階層への追加や削除を防ぎ、反復操作を予測可能にするため。

**Independent Test**: Issue、Task、Unlinkedの各ノードから追加し、親子関係、削除影響表示、展開状態を確認する。

**Acceptance Scenarios**:

1. **Given** Taskを選択している、**When** Taskを追加する、**Then** 新Taskは選択Taskの子として追加される。
2. **Given** IssueまたはUnlinkedを選択している、**When** Taskを追加する、**Then** 対応領域のルートTaskとして追加される。
3. **Given** Repository削除を選択する、**When** 確認画面を見る、**Then** 影響するIssueとTaskの件数が表示される。
4. **Given** TUIを再起動する、**When** 保存済みデータを表示する、**Then**前回の展開・選択状態を復元できる。

### Edge Cases

- 1文字のペイン幅にも収まらない幅広文字や結合文字を途中で壊さない。
- Closed Issueを非表示にしても配下TaskとProposalは保持する。
- 選択中Issueが非表示になった場合は、最も近い表示可能な行へ安全に選択を移す。
- メニューを開いている間に外部処理が失敗しても、閉じれば通常操作を継続できる。
- 選択対象がない操作、Repository未登録、Issue未取得では理由と次の操作を示す。

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: すべての本文行はペインの内側で折り返し、隣接ペインまたは枠へ描画してはならない。
- **FR-002**: ペイン名はそれぞれの上枠と同じ行へ表示しなければならない。
- **FR-003**: Detailsは折り返し後の表示行単位で上下・先頭・末尾へ移動できなければならない。
- **FR-004**: 通常画面はTaskの日常操作を直接提供し、Proposal・Repository・Issue操作は単一のポップアップメニューへ集約しなければならない。
- **FR-005**: メニューはProposal、Repository、Issueを識別可能なタブとして提示し、キーボードだけで切替・選択・取消できなければならない。
- **FR-006**: Issue操作は更新、詳細表示、GitHubで開く、Closed表示切替を含まなければならない。
- **FR-007**: Closed Issueは既定で非表示とし、利用者の明示操作で表示・再非表示にできなければならない。
- **FR-008**: Issueの表示切替はTask、Proposal、Issue snapshotを変更してはならない。
- **FR-009**: 展開状態はIssueの不変な識別情報とTask IDに対応付け、一覧順変更で別項目へ移ってはならない。
- **FR-010**: 選択Taskから追加したTaskはその直接の子、IssueまたはUnlinkedから追加したTaskはその領域のルートにならなければならない。
- **FR-011**: Repository削除確認は、設定削除後も保持される関連Issue数とTask数を表示しなければならない。
- **FR-012**: 展開状態、Closed表示設定、選択対象は再起動後に復元できなければならず、復元不能な対象は安全な既定位置へ戻さなければならない。
- **FR-013**: メニュー経由の既存操作はコマンドコアと同じ検証、確認、失敗時復旧を使用しなければならない。
- **FR-014**: ヘルプと操作文書は通常操作、メニュー操作、表示切替、スクロールを一致して説明しなければならない。

### Key Entities

- **TUI View State**: 選択対象、IssueとTaskの展開状態、Closed Issue表示設定、Details位置を表す利用者状態。
- **Menu**: 現在のタブ、選択項目、呼び出し元の選択を持つ一時的な操作画面。
- **Visible Tree Row**: Issue、Task、Unlinkedのいずれかを表し、折り返し後の表示高と選択対象を保持する行。

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 幅40以上の対応端末で、長いタイトルと本文が枠外へ描画されるケースが0件である。
- **SC-002**: Proposal・Repository・Issueの各管理操作へ、通常画面から3操作以内で到達できる。
- **SC-003**: Open・Closed混在状態で、既定表示からClosed表示の有効化と再無効化を各2秒以内に行える。
- **SC-004**: 200 Task・10階層・長文Issueを含む状態で、選択、展開、Details移動が2秒以内に反映される。
- **SC-005**: 再起動後に、直前のClosed表示設定と有効な展開・選択状態が100%復元される。
- **SC-006**: 新しいTUI操作の正常・取消・失敗経路が決定的な自動テストで検証される。

## Assumptions

- メニューは`m`で開き、`Tab`と`Shift-Tab`でタブを切り替え、`Esc`で閉じる。
- Closed以外のDeleted・Unavailable IssueはTask喪失を防ぐため既定表示を維持する。
- 表示状態はTask・Issue・Proposal本体と分離して保存する。
- マウス対応は維持するが、すべての操作はキーボードだけでも完了できる。
