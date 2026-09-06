---

description: "Implementation tasks for the fx-integrated task management core"
---

# Tasks: fx内蔵型タスク管理コア

**Input**: Design documents from `specs/001-integrate-fx-proposals/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Constitutionで必須。各テストタスクを対応実装より先に完了し、期待どおり失敗することを
確認してから実装する。

**Organization**: タスクはユーザーストーリー単位に編成し、各ストーリーを独立して実装・検証できる
ようにする。

## Format: `[ID] [P?] [Story] Description`

- **[P]**: 未完了タスクへの依存がなく、別ファイルで並行作業できる
- **[Story]**: `spec.md`のユーザーストーリーとの対応
- すべてのタスクに具体的なファイルパスを含める

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Zig 0.16の単一プロジェクトと、既存ztodoに準じたモジュール境界を初期化する。

- [X] T001 Zig 0.16.0、`zt` executable、library module、run/test stepsを定義する `build.zig` と `build.zig.zon`
- [X] T002 `main`を薄いentry point、`root`を公開module/test集約として初期化する `src/main.zig` と `src/root.zig`
- [X] T003 [P] CLI command union、exit code定数、未実装commandのparse骨格を作る `src/cli.zig`
- [X] T004 [P] core、proposal、GitHub、fx、platformのmodule directoryと空のmodule fileを計画構造どおり作る `src/core/`、`src/proposal/`、`src/integrations/github/`、`src/integrations/fx/`、`src/platform/`
- [X] T005 [P] CLI全command groupの補完骨格を作る `extras/zsh/completions/_zt`

**Checkpoint**: `zig build test`と`zig build`が空のmodule構造で成功する。

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: 全ユーザーストーリーを支えるpath、process、共通entity、State検証、Atomic保存、設定を実装する。

**⚠️ CRITICAL**: このPhaseが完了するまでユーザーストーリー実装を開始しない。

- [X] T006 [P] ztodo-fx専用XDG path、`ZTODO_FX_DATA_FILE`／`ZTODO_FX_CONFIG_FILE` override、既存ztodo path非参照の失敗テストを書く `src/core/paths.zig`
- [X] T007 ztodo-fx専用path解決と親directory作成を実装してT006を通す `src/core/paths.zig`
- [X] T008 [P] shellを介さないargv、cwd、stdin、env override、stdout/stderr上限、deadline、中断を注入可能にするProcessRunnerの失敗テストを書く `src/platform/process.zig`
- [X] T009 ProcessRunnerとtyped termination/output resultを実装してT008を通す `src/platform/process.zig`
- [X] T010 [P] IssueKey、IssueSnapshot、Task、status enum、Unicode title検証の単体テストを書く `src/core/task.zig`
- [X] T011 IssueKey、IssueSnapshot、Taskと検証helperを実装してT010を通す `src/core/task.zig`
- [X] T012 [P] StateRootのID一意性、parent存在、cycle、Issue整合、連続position、Proposal一意性のdecode検証テストを書く `src/core/state.zig`
- [X] T013 StateRoot、index/clone/deinit、全体不変条件検証を実装してT012を通す `src/core/state.zig`
- [X] T014 [P] schema version、16 MiB上限、Unicode round trip、不正JSON、sync/replace失敗時の既存保持テストを書く `src/core/store.zig`
- [X] T015 `state.json`のdecode/encode/load/Atomic saveを実装してT014を通す `src/core/store.zig`
- [X] T016 [P] Repositoryと絶対Workspaceの一対一制約、20件上限、除外pattern、Atomic config保存のテストを書く `src/integrations/github/config.zig`
- [X] T017 RepositoryConfig model、検証、load/save、add/set/delete/exclude操作を実装してT016を通す `src/integrations/github/config.zig`
- [X] T018 [P] 小文字`y`／`--yes`だけを確定とする確認、利用者向けerror分類、stdout/stderr分離のテストを書く `src/cli.zig`
- [X] T019 CLI共通confirmation、error mapping、path付き復旧messageを実装してT018を通す `src/cli.zig`

**Checkpoint**: Foundation ready。StateとConfigは個別にAtomic保存でき、外部commandを偽物へ差替えられる。

---

## Phase 3: User Story 1 - IssueからProposalを作成して確定する (Priority: P1) 🎯 MVP

**Goal**: 登録Workspaceを安全に調査してIssue単位Proposalを生成し、人間が編集・確認・承認して
Task treeへAtomicに追加できる。

**Independent Test**: sample Issueと読取Workspace、偽fxを使い、生成→編集→重複警告→承認を行い、
既存Taskを保持したまま候補全件が正しいtreeとして追加され、対象Proposalだけが消えることを確認する。

### Tests for User Story 1

- [X] T020 [P] [US1] Proposal JSON schema、1〜20候補、candidate ID、parent、position、cycle、重複、Unicode上限の失敗テストを書く `src/proposal/model.zig`
- [X] T021 [P] [US1] fx envelopeのunknown field許容、空`final_output`、非空session、fence、不正JSON、出力上限の契約テストを書く `src/integrations/fx/response.zig`
- [X] T022 [P] [US1] `fx permissions --json`からmutation、Terminal、外部Workspace、uploadのallow ruleを拒否するテストを書く `src/integrations/fx/permissions.zig`
- [X] T023 [P] [US1] 標準秘密patternとcustom exclusion、symlink escape、容量上限、cleanup失敗を扱うsnapshotテストを書く `src/platform/snapshot.zig`
- [X] T024 [P] [US1] Issueをuntrusted dataとして区切り、出力schemaとread-only指示を含み、秘密本文をlogしないpromptテストを書く `src/integrations/fx/prompt.zig`
- [X] T025 [P] [US1] argv/stdin/cwd/`FX_PERMISSION_MODE=ask`、`--json --no-save`、timeout、signal、stderr、retry分類の偽fx契約テストを書く `src/integrations/fx/client.zig`
- [X] T026 [US1] Proposal、CandidateTask、GenerationMetadataの所有権・検証・JSON decodeを実装してT020を通す `src/proposal/model.zig`
- [X] T027 [P] [US1] fx envelope parserとProposal byte抽出を実装してT021を通す `src/integrations/fx/response.zig`
- [X] T028 [P] [US1] 実効fx権限の事前診断とunsafe ruleのtyped errorを実装してT022を通す `src/integrations/fx/permissions.zig`
- [X] T029 [P] [US1] 除外済みprivate一時Workspaceの作成、read-only化、安全なowned-root cleanupを実装してT023を通す `src/platform/snapshot.zig`
- [X] T030 [P] [US1] Proposal専用prompt builderを実装してT024を通す `src/integrations/fx/prompt.zig`
- [X] T031 [US1] stdin非対話実行、16 MiB上限、10分deadline、最大2回の限定retry、認証・互換性errorを実装してT025を通す `src/integrations/fx/client.zig`
- [X] T032 [P] [US1] add/edit/delete/move/reparent、保存選択、中断時rollbackのProposal editor状態遷移テストを書く `src/proposal/editor.zig`
- [X] T033 [US1] Proposal editorの純粋な状態操作を実装してT032を通す `src/proposal/editor.zig`
- [X] T034 [P] [US1] 既存同一Issue Taskとの完全一致警告、二重確認、append順、Task ID採番、State保存失敗rollbackのテストを書く `src/proposal/apply.zig`
- [X] T035 [US1] Proposal全候補のTask tree変換、重複警告、同じState copy内のTask追加＋Proposal削除を実装してT034を通す `src/proposal/apply.zig`
- [X] T036 [P] [US1] 生成precondition、既存Proposal置換確認、各Issue一Draft、失敗・中断時State不変、snapshot cleanupのworkflowテストを書く `src/proposal/generator.zig`
- [X] T037 [US1] config→IssueSnapshot→snapshot→permissions→fx→validate→Atomic Draft保存の生成workflowを実装してT036を通す `src/proposal/generator.zig`
- [X] T038 [P] [US1] `proposal generate/show/edit/discard/approve`の引数、exit code、確認、error messageのCLIテストを書く `src/cli.zig`
- [X] T039 [US1] Proposal command群をparse・orchestrateし、prompt／responseを出力しないCLI表示を実装してT038を通す `src/cli.zig`
- [X] T040 [US1] 偽fxをPATHへ置いた生成→編集→承認end-to-end testを追加する `src/root.zig`

**Checkpoint**: US1は実モデルなしの決定的testで独立合格し、任意の実fx smoke testは通常suiteから分離される。

---

## Phase 4: User Story 2 - IssueとTaskをツリーで把握する (Priority: P2)

**Goal**: Issueをroot、Taskを任意階層の子孫として、未紐付けと非Open Issueも含めて安定表示する。

**Independent Test**: 複数Issue、未紐付け、200 Task、10階層、closed/deleted/unavailable snapshotを含む
Stateを表示し、所属、階層、兄弟順、完了状態を2秒以内に判別できることを確認する。

### Tests for User Story 2

- [X] T041 [P] [US2] Issue root、Unlinked root、preorder traversal、兄弟position、深い階層、欠損禁止のtree projectionテストを書く `src/core/tree.zig`
- [X] T042 [P] [US2] Unicode枝、完了marker、Issue状態、絞込み、200 Task・10階層性能のrendererテストを書く `src/cli/tree_renderer.zig`
- [X] T043 [US2] Stateから安定したIssue/Task tree projectionを構築する処理を実装してT041を通す `src/core/tree.zig`
- [X] T044 [US2] human-readable tree rendererとIssue状態labelを実装してT042を通す `src/cli/tree_renderer.zig`
- [X] T045 [P] [US2] `task ls [--issue]`の空状態、全root、Issue filter、非Open Issue表示のCLIテストを書く `src/cli.zig`
- [X] T046 [US2] `task ls`をcore tree projectionへ接続してT045を通す `src/cli.zig`
- [X] T047 [US2] 200 Task・10階層を2秒以内で表示する回帰benchmark testを追加する `src/root.zig`

**Checkpoint**: US2は外部ネットワークなしで保存済みStateだけから独立表示できる。

---

## Phase 5: User Story 3 - Taskを手動管理してIssueへ紐付ける (Priority: P3)

**Goal**: AIなしでTask追加・編集・完了・並替え・親子化・Issue紐付け・安全な削除を行える。

**Independent Test**: 空Stateから手動Task treeを作り、reparent/link/unlink/move/toggle/promote/cascadeを
実行し、再読込後も構造と順序が一致し、取消・保存失敗では変更されないことを確認する。

### Tests for User Story 3

- [X] T048 [P] [US3] add/edit/toggle、兄弟move、subtree reparent、link/unlink、cycle拒否、Issue継承の状態操作テストを書く `src/core/state.zig`
- [X] T049 [P] [US3] promote時の相対順序、cascade対象固定、clear、取消、State save失敗rollbackの削除テストを書く `src/core/state.zig`
- [X] T050 [US3] Task add/edit/toggle/move/reparent/link/unlinkをState copy上に実装してT048を通す `src/core/state.zig`
- [X] T051 [US3] promote-children、subtree delete、clearとposition再採番をAtomic適用できるよう実装してT049を通す `src/core/state.zig`
- [X] T052 [P] [US3] `task add/edit/toggle/move/reparent/link/unlink/del/clear`のparse、one-based境界、`--yes`、child policyのCLIテストを書く `src/cli.zig`
- [X] T053 [US3] 手動Task command群をcore操作とAtomic storeへ接続し、影響範囲を確認前に表示する `src/cli.zig`
- [X] T054 [US3] 空状態から保存・再読込を挟む手動Task tree end-to-end testを追加する `src/root.zig`

**Checkpoint**: US3はghとfxが存在しない環境でも独立して完了・検証できる。

---

## Phase 6: User Story 4 - GitHubの対象RepositoryとIssueを管理する (Priority: P4)

**Goal**: Repository/Workspaceを管理し、Open Issueを取得・更新し、障害時もsnapshotとTaskを保持する。

**Independent Test**: 偽ghで登録→Open Issue取得→closed/not-found/forbidden/network遷移を再現し、設定と
最後のIssue snapshotを保持したままローカルTask操作が続けられることを確認する。

### Tests for User Story 4

- [X] T055 [P] [US4] `gh issue list/view --json`のargv、上限、認証・権限・network・not-found分類、JSON ownershipの契約テストを書く `src/integrations/github/client.zig`
- [X] T056 [P] [US4] Open/closed/deleted/unavailable遷移、最終title/body保持、重複Issue mergeのテストを書く `src/integrations/github/issue.zig`
- [X] T057 [US4] shellなしgh adapter、Open Issue list、既知Issue refresh、typed errorを実装してT055を通す `src/integrations/github/client.zig`
- [X] T058 [US4] GitHub結果をIssueSnapshotへmergeし、失敗時にTask linkを保つ処理を実装してT056を通す `src/integrations/github/issue.zig`
- [X] T059 [P] [US4] `repo add/ls/set-workspace/del/exclude`と`issue ls/refresh/show/open`のCLI契約テストを書く `src/cli.zig`
- [X] T060 [US4] Repository/Workspace管理とIssue command群をConfig、GitHub adapter、Stateへ接続してT059を通す `src/cli.zig`
- [X] T061 [US4] 偽ghによるRepository登録→refresh→障害→snapshot継続のend-to-end testを追加する `src/root.zig`

**Checkpoint**: US4はGitHub障害と認証失敗を区別し、Stateを壊さず独立検証できる。

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: 全ストーリーにまたがる診断、文書、補完、安全性、最終検証を完成させる。

- [X] T062 [P] gh/fx存在・認証・capability・実効permission・pathを秘密なしで報告する`doctor`のテストを書く `src/cli.zig`
- [X] T063 `doctor` commandと導入・修復案内を実装してT062を通す `src/cli.zig`
- [X] T064 [P] gh/fx導入・認証、空状態、Repository/Workspace登録、最初のProposalまでを書く `docs/getting-started.md`
- [X] T065 [P] 全CLI構文、確認、exit code、error classを契約どおり記載する `docs/command-reference.md`
- [X] T066 [P] XDG保存先、override、schema、上限、標準/custom除外、旧ztodo非移行を記載する `docs/configuration.md`
- [X] T067 [P] gh/fx/unsafe permission/timeout/invalid output/破損Stateの復旧手順を書く `docs/troubleshooting.md`
- [X] T068 [P] プロジェクト概要、必要環境、quick start、詳細docs linkを更新する `README.md`
- [X] T069 CLI契約の全command、option、Task ID候補をZsh補完へ反映する `extras/zsh/completions/_zt`
- [X] T070 [P] prompt、response、credential、Issue bodyを通常log/errorへ出さないこととsnapshot escapeを検証するsecurity回帰テストを追加する `src/root.zig`
- [X] T071 `src/root.zig`へ全module test importを集約し、未登録moduleがないことを確認する `src/root.zig`
- [X] T072 `zig fmt --check build.zig src`、`zig build test`、`zig build`を実行し結果を記録する `specs/001-integrate-fx-proposals/quickstart.md`
- [X] T073 隔離データでquickstartの手動scenarioを実行し、実gh/fx smoke testの実行有無と制約を記録する `specs/001-integrate-fx-proposals/quickstart.md`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 Setup**: 依存なし。
- **Phase 2 Foundational**: Setup完了後。全ユーザーストーリーをBLOCKする。
- **Phase 3 US1**: Foundational完了後。MVP。
- **Phase 4 US2**: Foundational完了後に独立着手可能。US1承認結果でも追加検証できる。
- **Phase 5 US3**: Foundational完了後に独立着手可能。US2 renderer完成後はCLI表示まで統合できる。
- **Phase 6 US4**: Foundational完了後に独立着手可能。US1の実生成smoke testには必要。
- **Phase 7 Polish**: 採用する全ユーザーストーリー完了後。

### User Story Dependency Graph

```text
Setup -> Foundational -> US1 (Proposal MVP)
                    ├-> US2 (Tree display)
                    ├-> US3 (Manual Task operations)
                    └-> US4 (GitHub management)

US1 + US2 + US3 + US4 -> Polish
```

US1の決定的testはfixture Issue/Configで独立実行できる。実利用の完全な流れではUS4がRepositoryと
IssueSnapshotを供給し、US2が承認後treeを表示し、US3が追加編集を担う。

### Within Each User Story

- テストを先に書き、対象実装なしで期待どおり失敗することを確認する。
- model/contract parserをworkflowより先に実装する。
- core操作をCLI orchestrationより先に実装する。
- failure/rollback testを通してからstory checkpointへ進む。

### Parallel Opportunities

- SetupのT003〜T005はT001/T002後、別ファイルで並行可能。
- Foundationalのtest-firstタスクT006、T008、T010、T012、T014、T016、T018は別ファイル単位で並行可能。
- Foundational完了後、US1〜US4はfixture境界を使って並行着手可能。
- US1のT020〜T025、US2のT041〜T042、US4のT055〜T056は各moduleで並行可能。
- Polish文書T064〜T068は実装済みCLI契約を基準に並行可能。

---

## Parallel Examples

### User Story 1

```text
Task T020: Proposal model tests in src/proposal/model.zig
Task T021: fx response tests in src/integrations/fx/response.zig
Task T022: fx permission tests in src/integrations/fx/permissions.zig
Task T023: snapshot tests in src/platform/snapshot.zig
Task T024: prompt tests in src/integrations/fx/prompt.zig
Task T025: fx process tests in src/integrations/fx/client.zig
```

### User Story 2

```text
Task T041: Tree projection tests in src/core/tree.zig
Task T042: Tree renderer and performance tests in src/cli/tree_renderer.zig
```

### User Story 3

`src/core/state.zig`と`src/cli.zig`を順に変更するため、US3内部は直列を基本とする。US1、US2、US4とは
担当ファイル衝突を調整したうえで並行できる。

### User Story 4

```text
Task T055: GitHub process contract tests in src/integrations/github/client.zig
Task T056: Issue snapshot transition tests in src/integrations/github/issue.zig
```

---

## Implementation Strategy

### MVP First (User Story 1)

1. Phase 1 Setupを完了する。
2. Phase 2 Foundationalを完了する。
3. Phase 3 US1を完了する。
4. 偽fxによる生成→編集→重複警告→承認を独立検証する。
5. 実fx smoke testは明示的に実行し、通常test suiteへ混ぜない。

### Incremental Delivery

1. Setup + Foundationalで安全なStateと外部process境界を完成。
2. US1でProposal MVPを完成・検証。
3. US2でIssue/Task treeの可視化を追加。
4. US3で手動Task lifecycleを完成。
5. US4でGitHub Repository/Issue運用を完成。
6. Polishでdoctor、初期設定docs、補完、security、quickstartを完成。

### Parallel Team Strategy

Foundational完了後は、fx/Proposal、tree renderer、Task mutation、GitHub adapterを別担当に分けられる。
ただし`src/cli.zig`と`src/root.zig`の統合タスクはstoryごとに順番を調整する。

---

## Notes

- `[P]`は別ファイルかつ未完了依存がないタスクだけに付与した。
- `[US1]`〜`[US4]`はspecのstoryへ追跡可能。
- 実ネットワーク、認証、モデル応答は通常test suiteから分離する。
- 既存ztodoのsourceは設計参照に限り、保存ファイルを読込・移行する実装は追加しない。
- 各checkpointで停止してstoryを独立検証できる。

---

## Phase 8: Convergence

- [X] T074 TUIの統合ツリー上でTaskを親Task・Issue・Unlinkedへ明示的に移動できる操作と回帰テストを追加する `src/tui/app.zig`、`src/tui/model.zig` per FR-005/FR-007/FR-010 (partial)
- [X] T075 Task検索時に一致項目のIssue rootと祖先Taskを保持し、一致箇所まで展開したtree projectionのテストを追加する `src/tui/app.zig` per FR-009 (partial)
- [X] T076 Detailsペインへ独立スクロールを追加し、長いIssue本文とTask情報を末尾まで閲覧できるテストと操作文書を追加する `src/tui/app.zig`、`src/tui/model.zig`、`docs/tui.md` per FR-002 (partial)
- [X] T077 TUIの展開状態から固定Issue・Task件数上限を除き、任意の有限階層を扱える所有権とテストを追加する `src/tui/model.zig`、`src/tui/app.zig` per FR-006 (partial)
- [X] T078 TUIのTask削除確認に対象・子孫・昇格の影響を表示し、全Task消去を件数付き確認から実行できる操作とテストを追加する `src/tui/app.zig` per FR-004/FR-013 (partial)
