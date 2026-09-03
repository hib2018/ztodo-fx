# Feature Specification: fx内蔵型タスク管理コア

**Feature Branch**: `未作成（before_specifyフック未設定）`

**Created**: 2026-09-01

**Status**: Draft

**Input**: User description: "既存ztodoをベースにProposal生成を内蔵エージェントへ置き換え、
IssueとTaskをツリー表示し、GitHub管理、手動Task操作・Issue紐付け、
Proposal生成・人間介入・確定をアプリ内で完結させる"

## Clarifications

### Session 2026-09-02

- Q: GitHub Repositoryと、Proposal生成で読み取るローカルWorkspaceをどのように対応付けますか？
  → A: RepositoryごとにWorkspaceを一つ登録し、Proposal生成時はその場所を使用する。
- Q: 編集途中のProposalは、同時にいくつ保持できるようにしますか？
  → A: Issueごとに一つ保持し、異なるIssueのProposalは並行して保存できる。
- Q: Proposal内の候補が既存Taskと重複している可能性がある場合、承認をどう扱いますか？
  → A: 重複候補を警告し、人間が確認した場合は追加を許可する。
- Q: Taskに紐づくIssueがClose・削除・アクセス不能になった場合、そのTaskツリーをどこに
  表示しますか？ → A: 元のIssueを状態付きで表示し、その配下にTaskを保持する。
- Q: 子Taskを持つ親Taskを削除するとき、子Taskをどのように扱いますか？
  → A: 子Taskを一階層上へ昇格するか、サブツリー全体を削除するかを操作ごとに選択する。

## User Scenarios & Testing *(mandatory)*

### User Story 1 - IssueからProposalを作成して確定する (Priority: P1)

開発者は対象のGitHub Issueを選び、対象Workspaceのコードや文書を調査した
Proposalをアプリ内で生成する。生成結果を確認し、Task候補の追加、編集、削除、並べ替え、
親子関係の変更を行ったうえで、明示的に承認してTaskツリーへ反映する。

**Why this priority**: 外部AIへの貼り付けとClipboard経由のJSON取込をなくし、Issueから
実行可能なTaskを得る主要価値をアプリ内で完結させるため。

**Independent Test**: 読み取り可能なサンプルWorkspaceとIssueを用意し、Proposal生成、
編集、承認を行うことで、既存Taskを保持したまま候補全件が正しいツリーとして追加されることを
検証できる。

**Acceptance Scenarios**:

1. **Given** Issueに対応するWorkspaceが登録されている、**When** 利用者がProposal生成を
   明示的に開始する、**Then** エージェントはIssueとWorkspaceを読み取り、検証可能な
   Task候補と親子関係をアプリ内に提示する。
2. **Given** Proposalが表示されている、**When** 利用者が候補を編集、追加、削除、並べ替え、
   または親子関係を変更する、**Then** 変更後のProposalを再確認でき、既存Taskは変化しない。
3. **Given** 有効なProposalが表示されている、**When** 利用者が明示的に承認する、**Then**
   Proposal全体が対象Issue配下のTaskツリーへ一括追加され、既存Taskは削除も置換もされない。
4. **Given** Proposalに既存Taskとの重複候補が含まれる、**When** 利用者が承認を要求する、
   **Then** 重複候補が警告され、追加確認した場合に限り候補をそのまま追加できる。
5. **Given** Proposalが表示されている、**When** 利用者が却下または中断する、**Then**
   Taskツリーは変化せず、利用者が保存を選んだ編集済みProposalだけが対象Issueの下書きとして
   残り、他IssueのProposalは変化しない。

---

### User Story 2 - IssueとTaskをツリーで把握する (Priority: P2)

開発者は登録RepositoryのIssueをルートとして、そのIssueに紐づくTaskとサブTaskを
一つのツリーで確認する。Issueに紐づかない手動Taskも失われず、独立した領域で確認する。

**Why this priority**: Issueと実作業の対応およびTask間の分解関係を一覧だけで把握できることが、
日々の開発作業を選択する基盤になるため。

**Independent Test**: 複数Issue、複数階層のTask、未紐付けTaskを含むデータを表示し、全要素の
所属、階層、順序、完了状態を一意に読み取れることを検証できる。

**Acceptance Scenarios**:

1. **Given** 複数IssueへTaskとサブTaskが紐づいている、**When** 利用者がTask一覧を表示する、
   **Then** Issueをルート、Taskを子孫として、兄弟順序と完了状態を保ったツリーが表示される。
2. **Given** Issue未紐付けのTaskが存在する、**When** 利用者がTask一覧を表示する、**Then**
   そのTaskは未紐付け領域のツリーに表示される。
3. **Given** 子Taskを持つTaskが存在する、**When** 利用者が親Taskだけを完了にする、**Then**
   子Taskの完了状態は暗黙に変更されない。
4. **Given** Taskに紐づくIssueがCloseまたは取得不能である、**When** 利用者がTask一覧を
   表示する、**Then** Issueの状態を識別でき、そのIssue配下でTaskツリーを引き続き確認できる。

---

### User Story 3 - Taskを手動管理してIssueへ紐付ける (Priority: P3)

開発者はAIを使わずにTaskを追加、編集、完了、並べ替え、親子化し、Issueへの紐付けと解除を
行う。破壊的な操作では対象と影響を確認してから確定する。

**Why this priority**: Proposalを必要としない小さな作業や、生成後に発生した作業も同じ
Taskツリーで安全に管理できる必要があるため。

**Independent Test**: 空の状態から手動Taskを作成し、親子化、Issue紐付け、並べ替え、完了、
解除を行い、再表示後も状態と順序が維持されることを検証できる。

**Acceptance Scenarios**:

1. **Given** Issueと複数Taskが存在する、**When** 利用者がTaskをIssueまたは親Taskへ
   紐付ける、**Then** Taskとその子孫が整合する位置へ移動し、循環参照は作成されない。
2. **Given** 同じ親を持つ複数Taskが存在する、**When** 利用者が一つを並べ替える、**Then**
   その親の直下だけで兄弟順序が更新される。
3. **Given** 子Taskを持つTaskが存在する、**When** 利用者が親Taskの削除を要求する、**Then**
   子Taskを一階層上へ昇格するかサブツリー全体を削除するかを選択でき、影響範囲の確認後に
   選択した変更全体が一括適用される。
4. **Given** 削除または全消去が要求された、**When** 利用者が確認を完了しない、**Then**
   Taskは一件も変更されない。

---

### User Story 4 - GitHubの対象RepositoryとIssueを管理する (Priority: P4)

開発者は対象Repositoryを登録・一覧・削除し、登録RepositoryのOpen Issueを取得、更新、選択、
閲覧する。取得障害があってもローカルTaskの操作を継続できる。

**Why this priority**: Issue起点のワークフローに必要だが、既存のローカルTask管理はGitHubの
一時的な障害から独立して利用できる必要があるため。

**Independent Test**: Repositoryの登録からIssue一覧の取得までを行い、重複や不正形式を拒否し、
取得失敗時にも保存済みTaskが表示・操作できることを検証できる。

**Acceptance Scenarios**:

1. **Given** 有効なRepository識別子とWorkspaceが未登録である、**When** 利用者が両者を
   対応付けて登録する、**Then** RepositoryとWorkspaceの組が一度だけ保存され、Open Issueを
   取得できる。
2. **Given** Repositoryが登録されている、**When** Issue取得に失敗する、**Then** エラーと
   再試行手段が示され、ローカルTaskと保存済み設定は変更されない。
3. **Given** Repositoryに紐づくTaskが存在する、**When** 利用者がRepository設定の削除を
   要求する、**Then** 影響が提示され、明示的な確認なしには削除されない。

---

### Edge Cases

- Issueが削除、Close、またはアクセス不能になった場合も、Issue識別情報と最終取得情報を
  状態付きのIssueノードとして保持し、配下のTaskをローカルで表示・操作できる。
- 同じRepositoryまたは同じIssueが重複取得されても、ツリーに重複ノードを作らない。
- Taskを自身または自身の子孫へ移動しようとした場合は、循環になる操作を拒否する。
- 親Taskだけを削除して子Taskを昇格する場合、子Taskの相対順序とIssue所属を維持し、削除した
  親Taskがあった兄弟位置から連続して配置する。
- サブツリー削除の保存に失敗した場合は、親と子孫のいずれも削除しない。
- Proposalに空のTask一覧、候補同士の重複、長すぎる文字列、不明な親、循環参照がある場合は、
  承認を許可せず、修正箇所を示す。
- Proposal候補と同じIssueの既存Taskにタイトルの完全一致がある場合は重複候補として警告するが、
  利用者が追加確認すれば承認できる。
- Proposal生成が失敗、中断、または上限回数まで再試行しても完了しない場合は、既存Taskと
  既存Proposalを変更せず、再実行可能なエラーを示す。
- Workspace外を参照するリンクやパス、秘密情報と判定された内容は調査・送信対象から
  除外する。
- 保存先が書き込み不能、容量不足、または既存データが不正な場合は、既存ファイルを置換せず、
  復旧に必要な情報を示す。
- 非常に深いTask階層は省略せず表示しつつ、操作不能や循環を起こさない。

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: システムは、Repositoryを一意な識別子と一つのローカルWorkspaceの組として登録、
  一覧表示、編集、確認後に削除できなければならない。
- **FR-002**: システムは、登録RepositoryごとにOpen Issueを取得・再取得し、番号、タイトル、
  本文、状態、Repositoryとの関係を表示できなければならない。
- **FR-003**: GitHubの認証失敗、通信失敗、権限不足は区別可能なエラーとして示し、ローカルの
  Task操作を妨げてはならない。
- **FR-004**: システムは、Taskを追加、表示、編集、完了・未完了の切替、削除、全消去、
  並べ替えできなければならない。
- **FR-005**: 各Taskは、最大一つのIssueと最大一つの親Taskに所属できなければならない。
- **FR-006**: Taskの親子関係は任意の有限階層を表現でき、循環参照を拒否しなければならない。
- **FR-007**: 親Taskとその子孫は同じIssue所属または同じ未紐付け状態を共有しなければならず、
  Issueへの紐付け・解除時は部分的に不整合なツリーを残してはならない。
- **FR-008**: システムは、Issueをルート、そのTaskを子孫としてツリー表示し、未紐付けTaskは
  独立したルート領域に表示しなければならない。
- **FR-009**: ツリー表示はTaskの親子関係、兄弟順序、完了状態、Issue所属を識別可能に
  表現しなければならない。
- **FR-010**: Taskの並べ替えは同じ親の直下で行い、別の親またはIssueへの移動は明示的な
  再紐付け操作として扱わなければならない。
- **FR-011**: 親Taskの完了状態を変更しても、子孫の完了状態を暗黙に変更してはならない。
- **FR-012**: 子Taskを持つTaskの削除時は、子Taskを一階層上へ昇格するか、対象Taskと全子孫を
  削除するかを利用者が選択できなければならない。対象と影響範囲を確認後、選択した変更全体を
  一括適用し、部分的な移動または削除を残してはならない。
- **FR-013**: 削除、全消去、Repository設定の削除、Proposal承認は、対象と影響を示した明示的な
  確認を必要とする。
- **FR-014**: システムは、利用者が選択したIssueと、そのRepositoryに登録されたWorkspaceを
  入力として、Task候補、概要、順序、親子関係を含むProposalをアプリ内で生成できなければ
  ならない。
- **FR-015**: Proposal生成は利用者の明示的な操作でのみ開始し、Issue選択やアプリ起動だけでは
  開始してはならない。
- **FR-016**: Proposal生成中の調査は登録されたWorkspace内の読み取りに限定し、ファイル変更、
  ビルド、テスト、外部サービスの更新を行ってはならない。
- **FR-017**: システムは認証情報、秘密鍵、トークン、環境変数、Git認証情報、および設定された
  除外対象をProposal生成時の外部送信から除かなければならない。
- **FR-018**: Proposal生成の自動再試行は有限回で停止し、失敗理由と手動再試行手段を示さなければ
  ならない。
- **FR-019**: 生成Proposalは、Task反映前に形式、必須項目、文字数、件数、重複、親の存在、
  循環参照を検証しなければならない。
- **FR-020**: 利用者はProposal内のTask候補を追加、編集、削除、並べ替え、親子化、却下できなければ
  ならない。
- **FR-021**: 編集済みProposalはIssueごとに最大一つを下書き保存でき、異なるIssueのProposalを
  並行して保持できなければならない。保存せず中断した場合は、中断前の保存済みProposalを
  維持しなければならない。
- **FR-022**: Proposal承認は全候補を一回の操作でTaskへ追加し、一部だけが反映された状態を
  残してはならない。
- **FR-023**: Proposal承認は既存Taskを暗黙に削除、置換、並べ替え、または状態変更しては
  ならない。
- **FR-024**: Task、Proposal、Repository設定は、入力全体の検証成功後にのみ一括保存し、
  失敗または中断時は直前の有効なデータを維持しなければならない。
- **FR-025**: Proposal生成、編集、承認の主要フローは、プロンプトや応答をClipboardまたは
  別アプリへ手動転送せず完了できなければならない。
- **FR-026**: コマンド操作は、GitHub管理、手動Task・Issue紐付け、Proposal生成・人間介入・確定の
  3領域を識別可能なヘルプとエラー表示で提供しなければならない。
- **FR-027**: 保存済みTaskとProposalは、Proposal生成機能が利用不能でも表示・編集できなければ
  ならない。
- **FR-028**: システムは秘密情報をProposal、モデル応答、通常ログへ意図的に永続保存しては
  ならない。
- **FR-029**: Proposal候補のタイトルが同じIssue内の既存Taskと完全一致する場合は、対象を
  警告しなければならない。利用者が追加確認した場合は重複候補の追加を許可し、自動除外または
  自動統合してはならない。
- **FR-030**: Close、削除、またはアクセス不能なIssueにTaskが紐づいている場合、システムは
  その状態と最後に取得できたIssue情報を示すノードを表示し、配下のTaskを未紐付けへ自動移動、
  非表示、または削除してはならない。
- **FR-031**: 子Taskを一階層上へ昇格する場合は、子Taskの相対順序とIssue所属を維持し、
  削除した親Taskが占めていた兄弟位置から連続して配置しなければならない。

### Key Entities *(include if feature involves data)*

- **Repository**: GitHub上の作業対象。所有者と名称からなる一意な識別子、登録順、Issue集合、
  一つのWorkspaceとの対応を持つ。
- **Issue**: Repository内の作業要求。Repository、番号、タイトル、本文、最終取得時の状態、
  現在の取得可否で識別され、Open、Close、削除、アクセス不能にかかわらずTaskツリーの
  ルートになり得る。
- **Task**: 実行可能な作業単位。一意なID、タイトル、完了状態、兄弟順序、任意のIssue、任意の親Taskを
  持ち、子Taskを持てる。
- **Proposal**: 一つのIssueから生成されたTask候補の下書き。概要、候補Task、順序、親子関係、
  対象Issue、検証状態を持ち、承認前はTaskと分離される。同じIssueに保持できるProposalは
  最大一つである。
- **Workspace**: Repository登録時に一対一で対応付けられ、Proposal生成時にエージェントが
  読み取れるローカル範囲。対象パスと除外規則を持つ。
- **Generation Session**: 一回のProposal生成要求。対象Issue、Workspace、進行状態、有限の再試行、
  成功または失敗結果を表し、Taskを直接変更しない。

### Scope Boundaries

**In Scope**:

- Repository登録とOpen Issueの読み取り・選択
- 手動Task操作、Issue紐付け、Task親子関係、ツリー形式のコマンド表示
- Workspaceを読み取るProposal生成、検証、人間による編集、承認または却下
- 既存ztodoデータの安全性要件と、主要操作をアプリ内で完結させること

**Out of Scope**:

- TUIの実装
- GitHub Issueの作成、編集、Close、削除
- Proposal生成中のコード変更、ビルド、テスト、または実装作業
- 承認済みTaskの自動実行
- 複数利用者間のリアルタイム共有、権限管理、クラウド同期
- Clipboardを利用する従来Proposalフローの継続提供

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 利用者は、最大20件のTask候補を含むIssueについて、Issue選択からProposalの編集・
  承認までを、別アプリへの手動転送なしに5分以内で完了できる。
- **SC-002**: Proposalを却下、中断、または未承認のまま終了した100%の試行で、既存Taskに変更が
  発生しない。
- **SC-003**: 不正入力、生成失敗、書き込み失敗を含む検証ケースの100%で、直前の有効なTask、
  Proposal、Repository設定が読み出し可能な状態で維持される。
- **SC-004**: 200件のTaskと10階層の親子関係を含むデータを表示した際、利用者は2秒以内に
  Issue所属、親子関係、順序、完了状態を確認できる。
- **SC-005**: 代表的な利用シナリオの90%以上で、初見の利用者がヘルプを参照しながら、
  Repository登録、Task手動追加、Issue紐付け、Proposal承認を誤操作なく完了できる。
- **SC-006**: Proposalの編集・承認試験の100%で、追加・編集・削除・並べ替え・親子化・却下の
  いずれかを行った後も、承認前に最終結果を確認できる。

## Assumptions

- 対象利用者は、自分の開発用WorkspaceとGitHub Repositoryを操作する単一のローカル利用者である。
- 各Repositoryは登録時に一つのWorkspaceと対応付け、Proposal生成ごとのWorkspace選択は行わない。
- 既存ztodoと同様、GitHub連携は登録RepositoryのOpen Issueを読み取る用途に限定し、Issue自体の
  書き込み操作は本機能に含めない。
- GitHubへの認証は利用環境ですでに確立されており、本アプリは認証情報を独自保存しない。
- vercel-labs/fxを内蔵エージェントの基盤として使用することは製品要件であり、利用者は外部モデルの
  利用を理解している。モデル呼び出しごとの確認表示は不要とする。
- 一つのTaskが所属できるIssueと親Taskはそれぞれ最大一つとし、Task階層の深さには固定上限を
  設けない。
- 編集中ProposalはIssueごとに最大一つ、Proposal内のTask候補は最大20件、Taskタイトルは最大
  200文字とする。
- TUIはコマンドコアの契約が安定した後の別機能とし、本仕様ではコマンド操作と機械的に検証可能な
  コア動作を対象とする。
