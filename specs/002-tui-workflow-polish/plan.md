# Implementation Plan: TUIワークフロー改善

**Branch**: `main` | **Date**: 2026-09-06 | **Spec**: [spec.md](spec.md)

## Summary

既存の2ペインTUIを、幅内折り返しと枠内タイトルを持つ表示へ改修する。Taskの日常操作は通常画面に残し、Proposal・Repository・Issue操作は`m`で開くタブ付きメニューへ集約する。Closed Issueは表示状態だけで絞り、TUI View Stateをドメイン状態とは別ファイルへAtomic保存する。

## Technical Context

**Language/Version**: Zig 0.16.0
**Primary Dependencies**: Zig標準ライブラリ、Vaxis 0.6、既存Service／GitHub／Proposal adapter
**Storage**: 既存state/config JSONに加え、XDG state領域の`view.json`
**Testing**: Zig組込みtest、偽gh、描画projectionの単体テスト
**Target Platform**: macOS・Linux terminal
**Project Type**: ネイティブCLI/TUI
**Performance Goals**: 200 Task・10階層で入力から再描画まで2秒以内
**Constraints**: 幅40以上、Unicode graphemeを破壊しない、コア規則をTUIへ複製しない
**Scale/Scope**: 2ペイン、3 menu tab、既存Task/Issue/Proposal操作

## Constitution Check

| Gate | Result | Design |
|---|---|---|
| UI非依存コア | PASS | TUIは既存Serviceとadapterを呼び、表示状態だけを所有 |
| 人間統制Proposal | PASS | menu移設後も生成・編集・承認確認を維持 |
| データ完全性 | PASS | domain保存は既存Atomic経路、view stateも別途Atomic保存 |
| fx隔離 | PASS | TUIからfxを直接参照せずgeneratorを利用 |
| 自動検証 | PASS | projection、状態遷移、取消、失敗を偽外部processで検証 |

Post-designでも全Gateを満たす。

## Project Structure

```text
src/tui/app.zig
src/tui/model.zig
src/tui/layout.zig
src/tui/view_store.zig
src/application/service.zig
src/integrations/github/client.zig
src/core/paths.zig
docs/tui.md
```

**Structure Decision**: 折り返し・行高計算を`layout.zig`、表示状態の所有権とAtomic保存を`view_store.zig`へ分け、`app.zig`はイベント調停と描画に限定する。

## Complexity Tracking

違反なし。
