# Tasks: TUIワークフロー改善

**Input**: `specs/002-tui-workflow-polish/`

## Phase 1: Setup

- [X] T001 TUI追加moduleをtest集約へ登録する `src/root.zig`

## Phase 2: Foundational

- [X] T002 [P] Unicode表示幅による折り返しprojectionの失敗テストを書く `src/tui/layout.zig`
- [X] T003 [P] ViewStateの既定値・JSON round trip・不正参照・Atomic保存失敗テストを書く `src/tui/view_store.zig`
- [X] T004 折り返しprojectionを実装する `src/tui/layout.zig`
- [X] T005 ViewState modelと独立Atomic保存を実装する `src/tui/view_store.zig`、`src/core/paths.zig`
- [X] T006 ViewState、menu tab、安定node選択をTUI modelへ統合する `src/tui/model.zig`

## Phase 3: User Story 1 - 読みやすいTaskツリーと詳細表示 (P1)

- [X] T007 [US1] 長いUnicode行、深い罫線、Details表示行scroll、枠内titleの回帰テストを書く `src/tui/app.zig`、`src/tui/layout.zig`
- [X] T008 [US1] TreeとDetailsを幅内で折り返し、可変行高で選択・scrollする描画を実装する `src/tui/app.zig`
- [X] T009 [US1] ペイン名を上枠内へ描画しDetailsの`g`/`G`移動を実装する `src/tui/app.zig`

## Phase 4: User Story 2 - 管理操作をメニューから実行する (P1)

- [X] T010 [US2] 3タブmenuのopen・切替・選択・取消状態遷移テストを書く `src/tui/model.zig`
- [X] T011 [US2] `m`で開くProposal・Repository・Issueタブ付きpopupを実装する `src/tui/app.zig`
- [X] T012 [US2] 既存ProposalとRepository workflowをmenu actionへ移し通常画面の直接shortcutを整理する `src/tui/app.zig`

## Phase 5: User Story 3 - IssueをTUI内で管理する (P2)

- [X] T013 [US3] Closed既定非表示・toggle・選択補正のprojectionテストを書く `src/tui/app.zig`
- [X] T014 [US3] Issue menuへrefresh・details・GitHub open・Closed表示切替を実装する `src/tui/app.zig`
- [X] T015 [US3] GitHub openの成功・失敗を既存adapter境界で検証する `src/integrations/github/client.zig`、`src/tui/app.zig`

## Phase 6: User Story 4 - Task操作の細部を完成する (P2)

- [X] T016 [US4] 選択Taskの子・Issue root・Unlinked rootへの追加先テストと実装を追加する `src/tui/app.zig`
- [X] T017 [US4] Repository削除確認へ関連Issue・Task件数を表示する `src/tui/app.zig`
- [X] T018 [US4] 起動時ViewState復元と終了・表示変更時保存を統合する `src/tui/app.zig`、`src/tui/view_store.zig`

## Phase 7: Polish

- [X] T019 操作ヘルプとREADMEをmenu・Issue・折り返し・view復元に合わせる `docs/tui.md`、`README.md`
- [X] T020 全module整形、全test、build、quickstart差分検査を実行する `specs/002-tui-workflow-polish/quickstart.md`

## Dependencies

`T001 → (T002,T003) → (T004,T005) → T006 → US1 → US2 → US3 → US4 → Polish`

各User Storyは基盤完成後に独立検証する。テストtaskを対応実装より先に実行する。
