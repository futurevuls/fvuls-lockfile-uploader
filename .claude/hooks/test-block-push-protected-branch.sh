#!/usr/bin/env bash
# block-push-protected-branch.sh のルール(1)(push が実行されるディレクトリのブランチ判定)を
# 中心に、release の main checkout と feature の worktree を使ってケース別に検証する。
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "jq が必要です" >&2; exit 1; }

HOOK="$(cd "$(dirname "$0")" && pwd)/block-push-protected-branch.sh"

TMPROOT="$(mktemp -d)"
M="$TMPROOT/main"
W="$TMPROOT/wt"

cleanup() {
  git -C "$M" worktree remove --force "$W" >/dev/null 2>&1 || true
  git -C "$M" worktree remove --force "$W x" >/dev/null 2>&1 || true
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

git init -q -b release "$M"
git -C "$M" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m init
git -C "$M" worktree add -q -b feature "$W"
MB="$(basename "$M")"

# 空白を含むパスの保護 checkout(引用符付きパスのトークン化を検証するため)
git init -q -b release "$W repo"
git -C "$W repo" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m init

# 空白を含む feature worktree(二重引用符内のバックスラッシュ規則の検証用)
git -C "$M" worktree add -q -b feature2 "$W x"

# パスに文字どおりのバックスラッシュと空白を含む保護 checkout(同上)
git init -q -b release "$W\\ x"
git -C "$W\\ x" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m init

PASS=0
FAIL=0

# run <expected_exit> <cwd> <command> [CLAUDE_PROJECT_DIR] [nocwd]
#   [nocwd] に "nocwd" を渡すと、hook への stdin JSON から .cwd キー自体を省く
#   (cwd 欠落時の pwd フォールバックを検証するための特例。cwd はテスト実行側の
#   `cd` 先としては引き続き使う)。
run() {
  local expected="$1" cwd="$2" command="$3" proj="${4:-}" nocwd="${5:-}"
  local json errfile actual

  if [ "$nocwd" = "nocwd" ]; then
    json="$(jq -n --arg cmd "$command" '{tool_input: {command: $cmd}}')"
  else
    json="$(jq -n --arg cwd "$cwd" --arg cmd "$command" '{cwd: $cwd, tool_input: {command: $cmd}}')"
  fi

  errfile="$(mktemp)"
  if [ -n "$proj" ]; then
    (cd "$cwd" && CLAUDE_PROJECT_DIR="$proj" bash "$HOOK") <<<"$json" 2>"$errfile" >/dev/null
  else
    (cd "$cwd" && bash "$HOOK") <<<"$json" 2>"$errfile" >/dev/null
  fi
  actual=$?

  if [ "$actual" -eq "$expected" ]; then
    PASS=$((PASS + 1))
    printf 'PASS: [%s] %s\n' "$cwd" "$command"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL (expected %s, got %s): [%s] %s\n' "$expected" "$actual" "$cwd" "$command"
    head -n1 "$errfile" | sed 's/^/  stderr: /'
  fi
  rm -f "$errfile"
}

# 1. release にいる状態での素の push
run 2 "$M" "git push"
# 2. feature の worktree 内での push
run 0 "$W" "git push"
# 3. release にいながら -C で feature の worktree を指す push は許可
run 0 "$M" "git -C $W push"
# 4. feature の worktree にいながら -C で release 側を指す push
run 2 "$W" "git -C $M push"
# 5. cd で feature の worktree に移動してから push
run 0 "$M" "cd $W && git push"
# 6. cd で release 側に移動してから push
run 2 "$W" "cd $M && git push"
# 7. サブシェル記法は静的に追えないため fail-closed でブロックする
run 2 "$M" "(cd $W && git push)"
# 8. -C の相対パスは cd 後のディレクトリ基準で解決する
run 2 "$W" "cd $W && git -C ../$MB push"
# 9. cd は順に適用される(最後に適用された cd が有効)
run 2 "$M" "cd $W && cd $M && git push"
# 10. ルール(2): refspec の宛先が保護ブランチ
run 2 "$M" "git -C $W push origin HEAD:release"
# 11. ルール(3): refspec 無しで保護ブランチ名を直接指定
run 2 "$M" "git -C $W push origin release"
# 12. ルール(4): --all は保護ブランチを含みうる
run 2 "$M" "git -C $W push --all"
# 13. --dry-run は許可
run 0 "$M" "git push --dry-run"
# 14. push 以外は素通し
run 0 "$M" "git status"
# 15. CLAUDE_PROJECT_DIR はもう -C を上書きしない
run 0 "$M" "git -C $W push" "$M"
# 16. 解決できないパス(存在しない)は即座にブロックする(fail-closed)
run 2 "$M" "git -C /nonexistent/path push"
# 17. 未展開のシェル変数リテラル($WT)を含む場合も即座にブロックする(fail-closed)
run 2 "$M" 'git -C $WT push'
# 18. .cwd が無い JSON では pwd にフォールバックする
run 0 "$M" "git -C $W push" "" nocwd
# 19. パスをリテラルの二重引用符で囲んでも解決できる
run 0 "$M" "git -C \"$W\" push"
# 20. パスをリテラルの単一引用符で囲んでも解決できる
run 0 "$M" "cd '$W' && git push"
# 21. -C は git 呼び出しをまたいで累積しない(2 つ目の -C . はシェル cwd=release 基準)
run 2 "$M" "git -C $W log && git -C . push"
# 22. 絶対パスの -C なら呼び出しをまたいでも正しく解決できる
run 0 "$M" "git -C $W fetch && git -C $W push"
# 23. cd 後の shell の cwd を基準に -C の相対パスを解決する
run 0 "$M" "cd $W && git -C . push"

# --- 解析できる単純な形だけ許可し、それ以外は fail-closed ---
# 24. 括弧によるサブシェルはブロックする(subshell 内の cd は親シェルに影響しない)
run 2 "$M" "(cd $W && git status); git push"
# 25. push という字句が前方に現れても、後続の本物の push 呼び出しを見落とさない
run 2 "$W" "echo push && git -C $M push"
# 26. || を含む構文はブロックする(実行されない cd を誤って適用しない)
run 2 "$W" "cd $M || cd $W ; git push"
# 27. -c の後ろに続く -C も認識する
run 2 "$W" "git -c color.ui=false -C $M push"
# 28. 無害なグローバルオプション(-c <arg>)越しでも -C は解決できる
run 0 "$M" "git -c color.ui=false -C $W push"
# 29. 引数無しの無害なグローバルオプション(--no-pager)越しでも -C は解決できる
run 0 "$M" "git --no-pager -C $W push"
# 30. git を含まない chain(go test)は透過する
run 0 "$M" "cd $W && go test ./... && git push"
# 31. push 以外のサブコマンド(add/commit)は push 呼び出しとして記録しない
run 0 "$M" "git -C $W add -A && git -C $W commit -F msg && git -C $W push"
# 32. push 呼び出し後のパイプ(リダイレクト込み)は許可する
run 0 "$M" "git -C $W push 2>&1 | tail -5"
# 33. 複数の push 呼び出しは全件検査する
run 2 "$M" "git -C $W push && git -C $M push"
# 34. timeout などの前置ラッパは透過し、途中の git トークンから解析する
run 0 "$M" "timeout 60 git -C $W push"
# 35. ファイル名に "push" を含むだけで push トークンが無い形は素通し
run 0 "$M" "git log -- .claude/hooks/block-push-protected-branch.sh"
# 36. commit メッセージの引数内の "git push" を誤検出しない
run 0 "$W" "git commit -m \"see git push\" && git push"
# 37. 引用符内の "push" はトークンにならないので判定対象外(commit を push と誤検出しない)
run 0 "$M" "git commit -m \"see git push\""
# 38. 未対応の git グローバルオプション(--git-dir)はブロックする
run 2 "$W" "git --git-dir=$M/.git push"
# 39. 別シェル経由の cd は追えない
run 2 "$W" "bash -c \"cd $M\" && git push"
# 40. バックグラウンド実行(&)はブロックする
run 2 "$M" "git -C $W push &"
# 41. パイプライン内の cd(サブシェルで実行される)はブロックする
run 2 "$M" "cd $W | cat && git push"
# 42. cd 後の shell cwd を基準にした -C の相対パス解決(パイプライン検知の追加後も成立する)
run 0 "$M" "cd $W && git -C . push"

# --- 演算子がトークンに密着した形の正規化 ---
# 43. push&&true のように && が密着していても push 呼び出しとして見つける
run 2 "$M" "git push&&true"
# 44. 密着した && で 2 つの push 呼び出しをつないでいても両方検査する
run 2 "$W" "git -C $W push&&git -C $M push"
# 45. push> のようにリダイレクトが密着していても subcommand を push と認識する
run 2 "$W" "git -C $M push>/dev/null"
# 46. リダイレクトが密着していても、押し先が feature なら通す
run 0 "$M" "git -C $W push>/dev/null 2>&1"
# 47. push|cat のようにパイプが密着していても subcommand を push と認識する
run 2 "$W" "git -C $M push|cat"
# 48. push 呼び出しが無い(git status)場合は解析できた git 呼び出しの dir(=W)で判定する
run 0 "$W" "echo push && git status"
# 49. push が git より前にしか無い形は prefilter で素通し(実 push は必ず git…push の順に現れる)
run 0 "$M" "echo push && git status"
# 50. 引用符内の "push" はトークンにならないので判定対象外(commit 呼び出し自体はある)
run 0 "$W" "git commit -m \"see git push\""
# 51. cd 後でも、引用符内の "push" はトークンにならないので判定対象外
run 0 "$M" "cd $W && git commit -m \"see git push\""
# 52. git トークンが無くても push トークンがあれば shell の cwd で判定する(fail-closed)
run 2 "$M" "cat .gitconfig | grep push"
# 53. 同上、cwd が feature なら通す
run 0 "$W" "cat .gitconfig | grep push"
# 54. 密着した && + 非保護ブランチへの refspec push は通す
run 0 "$M" "git -C $W push origin HEAD:feature&&true"

# 55. 実際の改行を挟んだ2行目の push も検査する
run 2 "$W" "$(printf 'echo harmless\ngit -C %s push' "$M")"
# 56. pushd は cwd を変えうる未対応語としてブロックする
run 2 "$W" "pushd $M && git push"
# 57. command cd も同様にブロックする
run 2 "$W" "command cd $M && git push"
# 58. pipeline の後段セグメントの git push も検査する
run 2 "$W" "git status | git -C $M push"
# 59. 同上、押し先が feature なら通す
run 0 "$M" "git status | git -C $W push"
# 60. 実行ファイルのフルパス表記は git に正規化して解析する
run 2 "$W" "/usr/bin/git -C $M push"
# 61. \git のようなバックスラッシュ付き表記も git に正規化する
run 2 "$W" '\git -C '"$M"' push'
# 62. 同上、押し先が feature なら通す
run 0 "$M" "/usr/bin/git -C $W push"
# 63. 未展開のシェル変数($GIT)を実行ファイルに使う形はブロックする
run 2 "$W" '$GIT -C '"$M"' push'
# 64. 未展開のシェル変数($BRANCH)を refspec に使う形はブロックする
run 2 "$M" 'git -C '"$W"' push origin $BRANCH'
# 65. push 呼び出しが無いセグメントの pipeline は git 呼び出し側で判定する
run 0 "$M" "echo x | git -C $W push"
# 66. git を含まない push(未展開のシェル変数を含んでいても)は対象外
run 0 "$W" 'echo $PATH && npm run push'
# 67. サブコマンド前のリダイレクト(fd 番号)はブロックする
run 2 "$W" "git 2>/dev/null -C $M push"
# 68. サブコマンド後のリダイレクトは従来どおり許可する
run 0 "$M" "git -C $W push 2>/dev/null"
# 69. dry-run push の後ろに実 push が続く場合はその実 push を検査する
run 2 "$W" "git -C $W push --dry-run && git -C $M push"
# 70. release 上の dry-run push は検査対象外、実 push(W)だけを検査する
run 0 "$M" "git push --dry-run && git -C $W push"
# 71. パイプ付きでも dry-run push しか無ければ許可する
run 0 "$M" "git push --dry-run | tail -1"
# 72. -n も --dry-run と同様に扱う
run 0 "$M" "git push -n"
# 73. ; を含む場合は単一の単純コマンドとみなさずブロックする
run 2 "$M" "git push --dry-run; git push"
# 74. dry-run push の後ろに release への実 push が続く場合はブロックする
run 2 "$M" "git -C $W push origin HEAD:feature --dry-run && git push"
# 75. 単一の単純コマンドの dry-run は refspec の宛先に関わらず許可する
run 0 "$M" "git push origin HEAD:release --dry-run"
# 76. --dry-run は引数値の一部であってフラグではないので実 push として扱う
run 2 "$M" "git -c foo.bar=--dry-run push"
# 77. 同上、押し先が feature なら通す
run 0 "$M" "git -C $W -c foo.bar=--dry-run push"
# 78. 前方一致でも --dry-run フラグとしては扱わない(存在しないフラグ)
run 2 "$M" "git push --dry-run-ish"
# 79. 空白を含む保護パスをクォートで指定しても正しく解決してブロックする
run 2 "$M" "git -C \"$W repo\" push"
# 80. 同上、dry-run なら許可する
run 0 "$M" "git -C \"$W repo\" push --dry-run"
# 81. 閉じていないクォートはブロックする
run 2 "$W" "git -C \"$M push"
# 82. 引用符内の "push" はトークンにならないので判定対象外
run 0 "$M" "git commit -m \"fix: push it\""
# 83. 引用符内の && はトークン区切りにならない(commit メッセージの一部として扱う)
run 0 "$M" "git -C \"$W\" commit -m \"a && b\" && git -C \"$W\" push"
# 84. クォート付きの保護パスへの -C push はブロックする
run 2 "$W" "git -C \"$M\" push"
# 85. cd 先が空白を含む保護パスでもブロックする
run 2 "$M" "cd \"$W repo\" && git push"

# --- 行継続・コメント・別シェル経由・git 前のラッパオプション ---
# 86. バックスラッシュ+改行の行継続を挟んだ push も検査する
run 2 "$M" $'git \\\npush'
# 87. 行継続で分割された push の引数はそのまま許可判定できる
run 0 "$M" "$(printf 'git -C %s push \\\n-u origin feature' "$W")"
# 88. シェルコメントは bash と同様に無視する(--dry-run はコメントなので効かない)
run 2 "$M" "git push # --dry-run"
# 89. 同上、押し先が feature ならコメント越しでも通す
run 0 "$M" "git -C $W push # comment"
# 90. env -C は cwd を変えうるが解釈できないので fail-closed でブロックする
run 2 "$W" "env -C $M git push"
# 91. env の NAME=VALUE は透過する
run 0 "$M" "env GIT_TRACE=1 git -C $W push"
# 92. bash -c 経由は内側が 1 トークンにまとまり push 字句が見えなくてもブロックする
run 2 "$W" "bash -c \"git -C $M push\""
# 93. 実行ファイルのフルパス表記(/bin/bash)でも同様にブロックする
run 2 "$W" "/bin/bash -c \"git -C $M push\""
# 94. 別シェル経由の検査は --dry-run / -n の早期 return より先に行う
run 2 "$W" "bash -c \"git -C $M push\" -n"
# 95. eval 経由もブロックする
run 2 "$W" "eval \"git -C $M push\""
# 96. コマンド位置の . (source) はブロックする
run 2 "$W" ". ./setup.sh && git push"
# 97. パスとしての . はブロック対象外
run 0 "$W" "git -C . push"
# 98. timeout -k のような git 前のラッパオプションは fail-closed でブロックする
run 2 "$W" "timeout -k 5 60 git -C $M push"
# 99. nohup のような素の語は透過する
run 0 "$M" "nohup git -C $W push"

# --- 二重引用符内のバックスラッシュは bash の規則どおり($ ` " \ 改行の前だけ特殊) ---
# 100. \ の次が空白(非特殊文字)なので \ 自身を残す。実体は保護側 "$W\ x" への push
run 2 "$M" "git -C \"$W\\ x\" push"
# 101. 空白を含むだけの feature パスは従来どおり許可する
run 0 "$M" "git -C \"$W x\" push"
# 102. \$ は $ に潰れて存在しないパスになるので解決失敗で fail-closed
run 2 "$M" "git -C \"$W\\\$x\" push"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
