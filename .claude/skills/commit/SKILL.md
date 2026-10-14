---
description: "Pre-commit checks (branch / staged diff / gofmt on changed files) + auto-generated conventional commit message"
argument-hint: "optional message override (auto-generated from staged diff if omitted)"
---

# /commit — Safe commit with auto-generated message

`main` ブランチへの直 commit を防ぎ、staged diff から conventional commits 形式のメッセージを自動生成して commit を作成する。

## 入力

- 引数なし: staged 差分から件名・本文を自動生成
- 引数あり: その文字列を件名に使用 (本文は自動生成のまま)

## 手順

### Step 1 — Branch guard

```bash
BR=$(git branch --show-current)
echo "current: $BR"
```

`main` なら **即停止**(保護ブランチ)。フィーチャーブランチでなければ続行不可。

### Step 2 — Staged diff の確認

```bash
git status --short
git diff --cached --stat
git diff --cached
```

- `.env`, credentials, `*.pem`, `*.key` 等の機微ファイルが staged になっていれば停止して報告
- token・server UUID・顧客名などの実データ、社内の repo 名・チャット URL・issue 番号が差分に含まれていれば停止して報告(この repo は一般公開する。AGENTS.md「公開リポジトリ」)
- 期待外のファイル (例: 大量バイナリ、未関連ファイル) があれば停止して報告

### Step 3 — Quick checks (changed Go ファイルのみ)

`git diff --cached --name-only -- '*.go'` で staged された Go ファイルが存在する場合のみ:

```bash
mapfile -t FILES < <(git diff --cached --name-only -- '*.go')
if [ ${#FILES[@]} -gt 0 ]; then
  OUT=$(gofmt -l "${FILES[@]}") || { echo "gofmt failed"; exit 1; }
  [ -n "$OUT" ] && echo "$OUT" && echo "gofmt diff exists — run 'gofmt -w' on listed files" && exit 1
fi
```

### Step 4 — メッセージ生成

**言語は英語で書く (件名・本文ともに)。** ユーザーが明示的に「日本語で」と指示した時のみ日本語にする。

直近の commit log のスタイルを確認:

```bash
git log -20 --pretty=format:'%h %s'
```

`fix` のような極端に短い件名が並んでいてもそれに合わせない。conventional commits 形式で **diff の中身を要約** する:

- 形式: `<type>: <subject>` (**英語**、命令形、72 文字以内)
- type: feat / fix / refactor / docs / test / chore / perf / ci / build
- subject: WHAT より WHY を優先 (一行で表せない場合は本文に回す)
- 本文 (任意, 1 行空けて続ける、**英語**):
  - 主要な変更点を 1〜3 個の箇条書き
  - 動機 / 制約 / 副作用があれば追記

`git diff --cached` の中身を見て type を判定する目安:
- 既存機能のバグ修正 → `fix`
- 新規ファイル/機能追加 → `feat`
- 振る舞いを変えない再構成 → `refactor`
- `*_test.go` のみ → `test`
- `*.md` のみ → `docs`
- `.github/workflows/` のみ → `ci`
- `Dockerfile`, `go.mod` → `build`
- `.claude/` 等の開発ツール設定 → `chore`

複数 type にまたがる場合は最も支配的な変更に合わせ、本文で他の変更にも触れる。

### Step 5 — commit(確認なし)

生成したメッセージで **そのまま commit する**(/commit を明示起動した時点で承認とみなし、メッセージの OK 確認は取らない)。commit 後に SHA と `git status` を提示する。

```bash
git commit -m "$(cat <<'EOF'
<type>: <subject>

<body>
EOF
)"
git status
```

ただし Step 1(main ガード)・Step 2(機微 / 公開不可 / 想定外ファイル検出)の停止条件に当たった場合は commit せず報告する。これは“承認待ち”ではなく中断条件。

## 安全ルール

- **`main` 直 commit は絶対不可**。必ず別ブランチで作業
- `git add -A` / `git add .` を勝手に走らせない (機微ファイル混入リスク)。staged 済みのものを commit する
- `--amend` / `--no-verify` を勝手に使わない (ユーザーが明示要求したときのみ)
- pre-commit hook が失敗したら **新しい commit** を作成 (--amend ではない)
