---
description: "PR のタイトルと概要(本文)を差分から生成し gh pr edit で設定する"
argument-hint: "optional PR# (default: 現ブランチの open PR)"
---

# /pr-describe — PR タイトル・概要の生成と設定

現ブランチ(または指定 PR)の差分を要約し、タイトルと概要を生成して `gh pr edit` で設定する。

## 手順

### Step 1 — 対象 PR の解決

- 引数 `<PR#>` があればそれを使う。無ければ現ブランチの open PR を解決する。
  `gh pr list --head "$(git branch --show-current)" --json number --jq '.[0].number // empty'`
- 見つからなければ停止する(先に PR を作成する)。

### Step 2 — 差分の把握

- メタ情報を取得する: `gh pr view <PR> --json baseRefName,headRefName,files,commits,additions,deletions`
- `gh pr diff <PR>` で中身も確認する(要点把握のみ。全文は貼らない)。
- コミット見出し(`commits[].messageHeadline`)も要約材料にする。
- 粒度・トーンに迷ったら直近 merged PR 1〜2 件を `gh pr view` で見て合わせる。

### Step 3 — タイトル生成

- PR 全体を 1 行で表す。conventional な接頭辞(`feat` / `fix` / `chore` / `refactor` / `ci` 等)を付けてよい。
- 日本語で可。識別子・コマンド名はそのまま使う。ブランチ名の流用は禁止。

### Step 4 — 概要(本文)生成

必須 3 セクション:

- `## 概要` — 1〜4 行。fix は「症状 → 根本原因 → 対策」をここに畳む。WHAT より WHY
- `## 変更内容` — **ファイルパス先頭の箇条書き**(例: `- \`uploader.go\`: <挙動 1 つ>`)。互換性の要点 1 文だけ **太字**
- `## 動作確認` — 裏付けを規模に応じた形式で: CI(Lint / Test / Docker build)の結果 1 行、`gh act` の実行結果、長いログは `<details>` 折りたたみ。doc-only PR は「テスト対象なし(ドキュメントのみ)」と明記

条件付きセクション:

- `## スコープ外` — 分割 PR では必須。「何を含めず、なぜ今やらないか」まで書く
- `## レビュー観点 / 備考` — 互換性(登録 path・入力・tag)・リスク・見てほしい論点。中規模以上で推奨

文体・書式:

- 差分にある事実だけを書く。推測は「(推測)」と明示
- 箇条書きは 1 項目 1 論点。入れ子括弧だらけの長文にしない
- パス / 関数 / 設定キー / エラーコードはインライン `code`
- 誇張形容(「圧倒的」「劇的」等)を使わない。数値と事実で語る
- 空チェックボックス(`- [ ]`)は入れない
- markdown は 1 文 / 1 箇条書き = 1 行にする(文の途中で改行しない)

### Step 5 — 設定

- `gh pr edit <PR> --title '<title>' --body "$(cat <<'EOF' ... EOF)"` で設定する。
- 設定後に `gh pr view <PR> --json title,url` で結果を提示する。
- Draft 状態は変更しない(`gh pr ready` はユーザ判断)。

## 安全ルール

- `gh pr edit` 以外の破壊的操作はしない(merge / close / ready を勝手にやらない)。
- 差分に無い機能・変更を概要に書かない(hallucination 防止)。
- この repo は一般公開する。token・server UUID・顧客名などの実データと、社内の repo 名・チャット URL・issue 番号を本文に含めない。
