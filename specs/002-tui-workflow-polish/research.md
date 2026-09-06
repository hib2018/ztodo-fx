# Research: TUIワークフロー改善

## 折り返し

**Decision**: Unicode grapheme境界で表示幅を測り、論理行を表示行へprojectionする。
**Rationale**: 日本語や幅広文字を壊さず、選択行高とDetailsスクロールを同じ基準にできる。
**Alternatives considered**: byte切断はUTF-8を壊す。描画時だけの自動折り返しは選択・scroll位置を計算できない。

## メニュー

**Decision**: 単一modalにProposal、Repository、Issueの3 tabを置き、Tabで切り替える。
**Rationale**: 通常画面のkey負荷を減らし、管理機能を発見可能にする。
**Alternatives considered**: 個別shortcut継続は操作が見つけにくい。別画面遷移は選択contextを失いやすい。

## Closed Issue

**Decision**: view filterとして既定非表示にし、deleted/unavailableは表示する。
**Rationale**: 通常一覧を簡潔にしつつ、取得不能Issue配下のTaskを隠さない。

## View state

**Decision**: IssueKey、Task ID、選択node、Closed表示をdomain stateと別の`view.json`へ保存する。
**Rationale**: 一覧順に依存せず、UI設定で業務データschemaを変更しない。
**Alternatives considered**: index保存はrefreshでずれる。state.jsonへの追加はUI非依存原則を弱める。
