# Implementation Plan: fx内蔵型タスク管理コア

**Branch**: `001-integrate-fx-proposals` | **Date**: 2026-09-03 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/001-integrate-fx-proposals/spec.md`

## Summary

既存ztodoの小さなZig CLI構成を土台に、GitHub Issueをルート、Taskを子孫とするツリー型の
タスク管理コアを新規実装する。従来のClipboard経由Proposalフローは廃止し、利用者が別途
インストール・認証したfxの`ask`コマンドを、読み取り専用の専用アダプターから非対話実行する。
ProposalはIssue単位の下書きとしてコア状態に保存し、人間による編集と明示承認後にのみTaskへ
Atomicに反映する。既存ztodoとはデータを共有・移行せず、ztodo-fx専用の保存先と初期設定文書を
提供する。

## Technical Context

**Language/Version**: Zig 0.16.0（`build.zig.zon`の`minimum_zig_version`を正とする）

**Primary Dependencies**: Zig標準ライブラリ、GitHub CLI (`gh`)、利用者管理のfx CLI

**Storage**: XDG準拠のztodo-fx専用JSONファイル。Task、Issue snapshot、Proposalを単一の
`state.json`へAtomic保存し、RepositoryとWorkspace対応を`config.json`へAtomic保存する

**Testing**: Zig組み込み`test`、`std.testing.allocator`、一時ディレクトリ、偽`gh`／偽`fx`
実行ファイルによる契約・統合テスト

**Target Platform**: macOSおよびLinuxのネイティブCLI。WindowsとTUIは対象外

**Project Type**: 単一Zigプロジェクト（再利用可能なコアモジュール＋薄いCLI実行ファイル）

**Performance Goals**: 200 Task・10階層のツリーを2秒以内に表示。Proposal候補最大20件を
一回の承認で保存。外部コマンドの標準出力は上限付きで取得

**Constraints**: Proposal生成時に対象Workspaceを変更しない。fxの書込み・Terminal系ツールを
許可しない。秘密情報と除外対象をfxへ渡さない。生成の自動再試行は最大2回。既存ztodoの保存先を
読み書きしない。ネットワーク・認証がなくてもローカルTask操作は利用可能

**Scale/Scope**: Repository最大20件、Proposal候補最大20件、Taskタイトル最大200 Unicode
code point、状態ファイル最大16 MiB、単一ローカル利用者、Task階層は固定上限なし

## Constitution Check

*GATE: Phase 0開始前およびPhase 1設計後に確認。すべてPASS。*

| Gate | 判定 | 設計上の根拠 |
|---|---|---|
| UI非依存のコマンドコア | PASS | `core/`が全ドメイン規則を所有し、`cli.zig`は解析と表示だけを担う |
| 人間が統制するProposal | PASS | fx出力は下書きへ変換し、編集・警告・明示承認を経て一括適用する |
| Proposal生成は読み取り専用 | PASS | fxアダプターは権限事前検査、askモード、非対話実行、隔離された読取スナップショットを使う |
| データ完全性 | PASS | 関連するTaskとProposalを同じ`state.json`トランザクションでAtomic保存する |
| fx依存の隔離 | PASS | fx固有CLI、JSON envelope、権限診断を`integrations/fx/`に閉じ込める |
| 自動検証 | PASS | ドメイン単体、外部コマンド契約、失敗経路、JSON round tripを偽プロセスで検証する |
| 秘密情報の保護 | PASS | 除外済み一時スナップショットのみをfx Workspaceとし、prompt／responseを通常ログへ残さない |
| 初期CLI優先 | PASS | TUIモジュールを作らず、コアとCLI契約だけをPhase 1対象とする |

### Post-Design Re-check

Phase 1のデータモデル、CLI契約、fxアダプター契約、検証ガイドを再確認し、上記Gateはすべて
PASSのままである。違反の正当化やComplexity Trackingへの記載は不要。

## Project Structure

### Documentation (this feature)

```text
specs/001-integrate-fx-proposals/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── cli.md
│   ├── fx-adapter.md
│   └── proposal-output.schema.json
└── tasks.md                         # $speckit-tasksで後続作成
```

### Source Code (repository root)

```text
build.zig
build.zig.zon
src/
├── main.zig                         # 最小エントリーポイント
├── root.zig                         # 公開モジュールとtest集約
├── cli.zig                          # 引数解析、対話確認、出力、エラー変換
├── cli/
│   └── tree_renderer.zig            # Issue／Task treeのhuman-readable表示
├── core/
│   ├── task.zig                     # Task、IssueRef、親子・順序の不変条件
│   ├── state.zig                    # Task／Issue snapshot／Proposalの操作
│   ├── store.zig                    # state.jsonの検証・Atomic保存
│   └── paths.zig                    # ztodo-fx専用XDGパスとoverride
├── proposal/
│   ├── model.zig                    # Proposalと候補ツリーの検証
│   ├── editor.zig                   # 人間介入操作
│   ├── generator.zig                # Issue→fx request→下書き保存のworkflow
│   └── apply.zig                    # 警告確認後のAtomic適用
├── integrations/
│   ├── github/
│   │   ├── client.zig               # gh実行とIssue JSON解析
│   │   ├── config.zig               # Repository／Workspace設定
│   │   └── issue.zig                # Issue snapshot変換
│   └── fx/
│       ├── client.zig               # fx ask子プロセスと上限・中断
│       ├── permissions.zig          # 実効権限の事前診断
│       ├── prompt.zig               # Issueと出力契約からprompt生成
│       └── response.zig             # fx envelopeとProposal JSON解析
└── platform/
    ├── process.zig                  # 注入可能で上限付きの外部process実行
    └── snapshot.zig                 # 秘密情報を除外した一時読取スナップショット

docs/
├── getting-started.md               # gh／fx導入・認証、初回Repository登録
├── command-reference.md
├── configuration.md                 # 保存先、override、除外規則、上限
└── troubleshooting.md               # gh／fx／権限／生成失敗の診断

extras/zsh/completions/_ztodo-fx
```

**Structure Decision**: 既存ztodoの`core`、`proposal`、`integrations`、`platform`、薄い
`cli.zig`という責務分割を維持する。TUIとClipboardモジュールは初期スコープから除外する。
fx固有型は`integrations/fx`から外へ公開せず、`proposal/generator.zig`との境界では
`GenerationRequest`と検証済み`Proposal`だけを扱う。

## Complexity Tracking

Constitution違反はないため記載なし。
