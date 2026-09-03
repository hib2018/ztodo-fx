# Phase 0 Research: fx内蔵型タスク管理コア

## Zigとプロジェクト構造

**Decision**: Zig 0.16.0を使用し、既存ztodoの単一プロジェクト構造と責務分割を踏襲する。

**Rationale**: 既存ztodoとfxはいずれもZig 0.16.0を最低バージョンとしており、既存の
Allocator、`std.Io`、JSON、Atomic file、子プロセス処理のパターンを再利用できる。コアを
実行ファイルから分離すれば、将来のTUIも同じ操作を呼び出せる。

**Alternatives considered**:

- 別言語で再実装: 既存資産と運用知識を失うため不採用。
- fx内部ソースを直接import: 公開された安定ネイティブZigモジュールではなく、更新追従範囲が
  大きいため不採用。

## fx統合方式

**Decision**: 利用者が別途インストール・認証したfxを、`fx ask --json --no-save`として
子プロセス実行する。promptは標準入力で渡し、stdoutの単一JSON envelopeから`final_output`を
取り出す。

**Rationale**: fx公式CLIがプログラム連携用JSON出力とstdin入力を提供している。引数へIssue本文を
載せず、セッションを保存しないことで、プロセス一覧とfx履歴への不要な情報残存を抑えられる。
ztodo-fxのドメインはfxの内部型に依存しない。

**Alternatives considered**:

- fx内部Zigコードの直接組込み: 非公開内部境界への結合がconstitutionに反するため不採用。
- fx WASM core: 新しいWASM hostとネットワーク・ストレージbridgeが必要で初期CLIには過剰。
- fx同梱または自動取得: OS／CPU別配布、更新、供給元検証をztodo-fxが負うため不採用。

## fx読み取り専用境界

**Decision**: 次の多層防御を全て通過した場合だけProposal生成を開始する。

1. `fx permissions --json`で実効ルールを検査し、書込み、削除、rename、copy、folder作成、
   Terminal、外部Workspaceへの許可ルールがあれば拒否する。
2. 子プロセスへ`FX_PERMISSION_MODE=ask`を設定する。非対話`fx ask`では未解決の承認要求が
   実行されず停止する。
3. 登録Workspaceを直接渡さず、設定された除外規則と標準秘密ファイル規則を適用した
   一時スナップショットを作り、そのディレクトリをfxのprimary Workspaceにする。
4. スナップショットをOS上で読取専用にし、fxには変更・Terminal・外部調査を禁止する
   Proposal専用指示と厳密な出力契約を渡す。
5. fx終了後は出力をztodo-fx側で再検証し、一時スナップショットを破棄する。

**Rationale**: promptだけでは書込み禁止と秘密情報除外を保証できず、`ask`モードより先に利用者の
保存済みallow ruleが評価される。権限事前検査と除外済みWorkspaceにより、利用者の元Workspaceを
変更せず送信範囲を制御する。一時スナップショット作成はztodo-fxの準備処理であり、エージェントが
対象Workspaceを変更するものではない。

**Alternatives considered**:

- `FX_PERMISSION_MODE=ask`のみ: 保存済みallow ruleを防げないため不十分。
- promptだけで禁止: モデル誤動作を技術的に遮断できないため不採用。
- OS固有sandboxのみ: macOSとLinuxで同じ保証を提供しにくいため、補助策に限定。

## fx互換性と失敗処理

**Decision**: 起動前診断で`fx`の存在、`ask --json --no-save`、stdin、`permissions --json`、認証状態を
確認する。機能検出で契約を満たさない版は非互換として停止し、Task操作には影響させない。
stdout／stderrは各16 MiB、生成時間は既定10分、再試行は一時的な通信・provider障害だけ最大2回とする。

**Rationale**: fxはExperimentalであり、見かけのバージョン番号だけより必要機能の検出が安全。
上限により暴走プロセスと無制限メモリ消費を防ぐ。形式不正、権限拒否、認証失敗は再試行しない。

**Alternatives considered**:

- 特定fxバージョンだけを固定: 配布を利用者へ委ねる方針と相性が悪い。
- 全失敗を自動再試行: 費用増加と同じ不正出力の反復を招く。

## GitHub連携

**Decision**: 既存ztodo同様、`gh`を引数配列で子プロセス実行し、Open Issue取得と個別Issue更新を
JSONで受け取る。認証情報はztodo-fxに保存しない。

**Rationale**: GitHub認証とToken lifecycleを既存の信頼境界に委譲できる。GitHub障害時にも
state内の最終Issue snapshotとローカルTaskを利用できる。

**Alternatives considered**:

- GitHub APIへ直接接続: Token保存、HTTP client、rate limit処理の範囲が拡大する。

## 永続化とztodo非互換方針

**Decision**: `ztodo-fx`名前空間に新しいschema version 1を作り、既存ztodoのファイルを探索、
読込、移行しない。Task、Issue snapshot、IssueごとのProposalを単一`state.json`へ保存し、
Repository／Workspace設定は`config.json`へ保存する。

**Rationale**: Proposal承認時にTask追加とProposal削除を一つのAtomic置換にできる。旧ztodoと
交互に実行して新フィールドを失う危険がない。設定と状態は独立しているため、GitHub設定障害でも
保存済みTaskを操作できる。

**Alternatives considered**:

- 旧ztodoファイルを直接更新: parent、順序、Workspace情報を旧アプリが失う。
- 初回自動移行: ユーザーが明示的に選んだ「空から開始」に反する。
- ProposalをIssueごとの別ファイルに保存: Task適用とProposal削除を単一Atomic操作にできない。

## Taskツリー表現

**Decision**: Taskは不変`id`、任意`parent_id`、同じ親内の連続した`position`、任意`issue_key`を持つ。
親子は同じIssue所属を共有し、循環、存在しない親、重複positionをdecodeと変更の両境界で拒否する。

**Rationale**: 表示順とIDを分離でき、任意階層、部分ツリー移動、子昇格、cascade削除を一貫して
表現できる。隣接リストは200 Task規模で十分単純。

**Alternatives considered**:

- materialized path: 移動時に全子孫を書換える必要がある。
- nested set: 更新が複雑で小規模ローカルCLIには不適切。
- JSONの再帰ネスト: ID検索、部分更新、親参照検証が複雑。

## テスト戦略

**Decision**: Zigテストを対象モジュールと同じファイルへ置き、fx／ghはPATH上の偽実行ファイルまたは
注入したProcessRunnerで置換する。実認証・実ネットワーク試験は通常suiteから分離する。

**Rationale**: 終了コード、巨大出力、stderr、timeout、中断、不正JSON、空`final_output`、権限拒否を
決定的に再現でき、利用者の認証・Workspace・モデル費用へ影響しない。

**Alternatives considered**:

- 実fxだけのE2E: 遅く非決定的で通常の品質ゲートにできない。
- adapterをmockするだけ: 子プロセスとJSON envelopeの契約破損を検出できない。

## 初期設定ドキュメント

**Decision**: `docs/getting-started.md`を必須成果物とし、ghとfxの導入・認証、Repositoryと絶対
Workspaceパスの登録、権限診断、除外規則、最初のIssue取得とProposal生成を記載する。

**Rationale**: fxを同梱せず旧データも移行しないため、初回成功までの外部依存と空状態を明示する
必要がある。

**Alternatives considered**:

- READMEだけに全手順を記載: 概要と詳細手順が混在し、トラブルシュートを保守しにくい。

## Primary references

- [fx README](https://github.com/vercel-labs/fx): Zig 0.16、`fx ask --json`、`--no-save`、
  非対話権限動作、公開embedding surface
- [fx ask documentation](https://fx.sh/docs/using-fx/fx-ask): stdin、JSON envelope、session保存、
  非対話実行時の権限処理
- [fx permissions documentation](https://fx.sh/docs/configure-fx/permissions): ask／auto／yolo mode、
  保存済みruleの評価順、`FX_PERMISSION_MODE` process override、実効権限診断
- `/Users/hibik/dev/projects/ztodo`: 既存モジュール構造、Zig 0.16、gh連携、JSON検証、Atomic保存、
  テスト規約のローカル一次資料
