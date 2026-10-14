#!/usr/bin/env bash
# PreToolUse(Bash) hook — Claude による保護ブランチ(release/master/main)を
# 更新する push をブロックする。
#
# 脅威モデル: 対象は Claude が通常書く形のコマンドの誤 push を止めること。alias や
# 実行時にしか決まらないコマンド名など意図的な難読化は対象外。
#
# 仕様:
#   - stdin で PreToolUse の JSON を受け取り、`git push` 系コマンドのときだけ判定する。
#     `git` と `push` の大小文字を無視して照合するため、`$GIT` のように変数名に隠れた形も
#     判定対象になる(実際に未展開の変数かどうかは Step 1 の `$` チェックで見る)。
#   - コマンド文字列はクォート対応でトークン化する(引用された空白含みパスを 1 トークンとして
#     解決し、引用符内の `push` はサブコマンドとして扱わない)。閉じていないクォートは
#     fail-closed でブロックする。行継続(`\`+改行)とシェルコメント(`#`)は bash と同じに
#     解釈する(行継続は読み飛ばして 1 コマンドとして扱い、コメントはトークンに含めない)。
#   - 別シェル / eval / source 等の経由検査(`bash`・`sh`・`eval`・`pushd`・コマンド位置の
#     `.` 等、実行ファイル表記はベース名で照合)は、`push` という字句の有無や `--dry-run` に
#     関係なく、トークン化した直後に最優先で行う。
#   - 次のいずれかに該当すればブロックする(保護ブランチをリモート更新しうる push):
#       (1) push 先のリポジトリ(cwd / 先行する cd <path> / その git 呼び出しの -C <path>)の
#           ブランチが保護ブランチ。cd・-C を静的に追えない構文(改行・`;` `||` サブシェル・
#           未展開変数・別シェル経由・未知の git グローバルオプション・サブコマンド前の
#           リダイレクト・git 前のラッパオプション(`env -C` `timeout -k` 等)・閉じていない
#           クォート)は fail-closed でブロック
#       (2) refspec の宛先が保護ブランチ(例: `git push origin HEAD:release`、`:master`)
#       (3) refspec 無しで保護ブランチ名を直接指定(例: `git push origin release`)
#       (4) `--all` / `--mirror`(全ローカルブランチを push し保護ブランチを含みうる)
#   - 該当時は exit 2 で停止し、理由を stderr に出す(stderr は Claude とユーザに表示される)。
#   - `--dry-run` / `-n` は、単一の単純コマンドなら無条件に許可する。連結コマンド内では
#     dry-run の push 呼び出しだけを検査対象から外し、実 push は通常どおり判定する。
#   - 人間が手動ターミナルで実行する push には影響しない
#     (hook は Claude のツール呼び出しに対してのみ発火するため)。
set -euo pipefail

input="$(cat)"
cmd=""
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
fi
# jq 不在、または jq があっても抽出に失敗して空になった場合(JSON スキーマ変更/破損時など)は、
# 生 JSON 全体をパターン照合の対象にする(fail-open を避け fail-closed に倒す)。
[ -z "$cmd" ] && cmd="$input"

# git push 以外は素通し。大小文字を無視して照合する("$GIT" のように変数名に隠れた
# 形も拾い、実際に未展開かどうかの判定は Step 1 の $ チェックに委ねる)。
case "$(printf '%s' "$cmd" | tr 'A-Z' 'a-z')" in
  *git*push*) ;;
  *) exit 0 ;;
esac

# 判定前にシェルのクォート文字を除去する(Claude が引数を "release" / 'release' のように
# クォートしても確実に照合できるようにする。ルール(2)(3)(4)と Step 1 の部分一致チェックは
# fail-closed 側なので、クォート対応トークナイザではなく従来どおりこの scan を使う)。
scan="${cmd//\"/}"
scan="${scan//\'/}"

# 改行の構造チェック専用: `\`+改行(行継続)のペアを取り除いた scan。バックスラッシュ自体や
# 他の特殊文字の並びには影響しないため、素の改行(複数コマンドの区切り)だけを検出できる。
_scan_nl="${scan//\\$'\n'/}"

# クォートを尊重してコマンド文字列をトークン化する。空白 IFS の単純分割(や、クォートを
# 先に取り除いてからの分割)はクォート内の空白で語境界を失う(`git -C "/a/b c" push` が
# -C /a/b + サブコマンド c になってしまう)ため、1 文字ずつ走査して自前でトークンに切る。
# 結果は TOKS に積み、閉じていないクォートがあれば TOKENIZE_UNTERMINATED=1 を立てる
# (呼び出し側で fail-closed にブロックする)。
_tok_flush() {
  if [ "${_tok_have_cur:-0}" -eq 1 ]; then
    TOKS+=("$_tok_cur")
    _tok_cur=""
    _tok_have_cur=0
  fi
}

tokenize() {
  local s="$1"
  local i=0 n=${#s} c
  local in_squote=0 in_dquote=0
  TOKS=()
  TOKENIZE_UNTERMINATED=0
  _tok_cur=""
  _tok_have_cur=0

  while [ "$i" -lt "$n" ]; do
    c="${s:$i:1}"

    if [ "$in_squote" -eq 1 ]; then
      if [ "$c" = "'" ]; then
        in_squote=0
      else
        _tok_cur+="$c"
        _tok_have_cur=1
      fi
      i=$((i + 1))
      continue
    fi

    if [ "$in_dquote" -eq 1 ]; then
      if [ "$c" = '"' ]; then
        in_dquote=0
      elif [ "$c" = '\' ] && [ "$((i + 1))" -lt "$n" ]; then
        # bash 仕様どおり、二重引用符内でバックスラッシュが特殊化されるのは
        # $ ` " \ 改行 の直前だけ(それ以外の前では \ 自身をトークンに残す)。
        _dq_next="${s:$((i + 1)):1}"
        case "$_dq_next" in
          '$' | '`' | '"' | '\')
            _tok_cur+="$_dq_next"
            _tok_have_cur=1
            ;;
          $'\n')
            : # 行継続(バックスラッシュ+改行): 両方捨てる
            ;;
          *)
            _tok_cur+="\\$_dq_next"
            _tok_have_cur=1
            ;;
        esac
        i=$((i + 1))
      else
        _tok_cur+="$c"
        _tok_have_cur=1
      fi
      i=$((i + 1))
      continue
    fi

    case "$c" in
      "'")
        in_squote=1
        ;;
      '"')
        in_dquote=1
        ;;
      '\')
        if [ "$((i + 1))" -lt "$n" ]; then
          if [ "${s:$((i + 1)):1}" = $'\n' ]; then
            : # 行継続(バックスラッシュ+改行): 両方捨てる
          else
            _tok_cur+="${s:$((i + 1)):1}"
            _tok_have_cur=1
          fi
          i=$((i + 1))
        else
          _tok_cur+="$c"
          _tok_have_cur=1
        fi
        ;;
      '#')
        if [ "${_tok_have_cur:-0}" -eq 0 ]; then
          # シェルコメント: トークン先頭位置に来たときだけ、次の改行(または末尾)まで
          # 読み飛ばす(トークン途中の # は下の catch-all で通常の文字として扱われる)。
          while [ "$i" -lt "$n" ] && [ "${s:$i:1}" != $'\n' ]; do
            i=$((i + 1))
          done
        else
          _tok_cur+="$c"
          _tok_have_cur=1
        fi
        ;;
      ' ' | $'\t' | $'\n')
        _tok_flush
        ;;
      '&')
        _tok_flush
        if [ "${s:$((i + 1)):1}" = "&" ]; then
          TOKS+=("&&")
          i=$((i + 1))
        else
          TOKS+=("&")
        fi
        ;;
      '|')
        _tok_flush
        if [ "${s:$((i + 1)):1}" = "|" ]; then
          TOKS+=("||")
          i=$((i + 1))
        else
          TOKS+=("|")
        fi
        ;;
      '>')
        _tok_flush
        if [ "${s:$((i + 1)):1}" = ">" ]; then
          TOKS+=(">>")
          i=$((i + 1))
        else
          TOKS+=(">")
        fi
        ;;
      '<' | ';' | '(' | ')' | '{' | '}' | '`')
        _tok_flush
        TOKS+=("$c")
        ;;
      *)
        _tok_cur+="$c"
        _tok_have_cur=1
        ;;
    esac
    i=$((i + 1))
  done
  _tok_flush
  if [ "$in_squote" -eq 1 ] || [ "$in_dquote" -eq 1 ]; then
    TOKENIZE_UNTERMINATED=1
  fi
}

tokenize "$cmd"
_r1_all=("${TOKS[@]}")
_r1_n=${#_r1_all[@]}

# 実行ファイル表記の正規化: /usr/bin/git や /opt/homebrew/bin/git → git。
# \git はトークナイザがバックスラッシュを処理済みなので、この時点で既に git になっている。
_r1_ni=0
while [ "$_r1_ni" -lt "$_r1_n" ]; do
  case "${_r1_all[$_r1_ni]}" in
    */git) _r1_all[$_r1_ni]="git" ;;
  esac
  _r1_ni=$((_r1_ni + 1))
done

reason=""
# reason が「解析できなかった(構文/オプション/特定不能)」ことによるものなら 1。
# ブランチ判定そのものの reason(保護ブランチだった)では立てない。
reason_is_syntax=""

# 閉じていないクォートはトークン化そのものが信頼できない(残りの引数がすべて 1 つの
# トークンに巻き込まれる等)ので、以降の解析には進まず fail-closed でブロックする。
if [ "$TOKENIZE_UNTERMINATED" -eq 1 ]; then
  reason="閉じていないクォート"
  reason_is_syntax=1
fi

# 別シェル / eval / source 等の経由検査。push という字句の有無や --dry-run に関係なく、
# トークン化した直後・最優先で行う(bash -c "git ... push" のように内側の呼び出しが
# 1 トークンにまとまり push 字句が見えない形や、コメント/行継続経由で dry-run の早期
# return に落ちる形を、Step 0 や dry-run 判定より先に止めるため)。実行ファイル表記は
# パス部分を無視したベース名(最後の / より後ろ)で照合する。
if [ -z "$reason" ]; then
  _ws_seg_start=1
  _ws_i=0
  while [ "$_ws_i" -lt "$_r1_n" ] && [ -z "$reason" ]; do
    _ws_tok="${_r1_all[$_ws_i]}"
    case "$_ws_tok" in
      '&&' | '|')
        _ws_seg_start=1
        _ws_i=$((_ws_i + 1))
        continue
        ;;
    esac
    _ws_base="${_ws_tok##*/}"
    case "$_ws_base" in
      bash | sh | zsh | dash | ksh | fish | eval | exec | xargs | source | \
      pushd | popd | command | builtin)
        reason="push 先のリポジトリを特定できない構文"
        reason_is_syntax=1
        ;;
      .)
        # ドットコマンド(source)はコマンド位置(セグメント先頭)にあるときだけ対象にする。
        # git -C . push のようなパスとしての . は対象外。
        if [ "$_ws_seg_start" -eq 1 ]; then
          reason="push 先のリポジトリを特定できない構文"
          reason_is_syntax=1
        fi
        ;;
    esac
    _ws_seg_start=0
    _ws_i=$((_ws_i + 1))
  done
fi

# --dry-run / -n は、単一の単純コマンドなら無条件に許可する(連結コマンド内の dry-run は
# Step 2 で push 呼び出しごとに判定するので、ここでは対象にしない)。reason が既に立って
# いれば(閉じていないクォート・別シェル経由など)dry-run の早期 return より優先してブロック
# を確定させるので、ここでは判定しない。
_dr_has_flag=0
if [ -z "$reason" ]; then
  for _dr_t in "${_r1_all[@]}"; do
    case "$_dr_t" in
      --dry-run | -n)
        _dr_has_flag=1
        break
        ;;
    esac
  done
fi
if [ "$_dr_has_flag" -eq 1 ]; then
  _dr_simple=1
  case "$_scan_nl" in
    *$'\n'* | *';'* | *'|'* | *'('* | *')'* | *'{'* | *'}'* | *'`'* | *'$'* | *'&&'*)
      _dr_simple=0
      ;;
  esac
  if [ "$_dr_simple" -eq 1 ]; then
    _dr_amp="${scan//&&/}"
    _dr_amp="${_dr_amp//>&/}"
    _dr_amp="${_dr_amp//<&/}"
    _dr_amp="${_dr_amp//&>/}"
    case "$_dr_amp" in
      *'&'*) _dr_simple=0 ;;
    esac
  fi
  [ "$_dr_simple" -eq 1 ] && exit 0
fi

PROTECTED_RE='release|master|main'

# (4) --all / --mirror は全ローカルブランチ(保護ブランチ含む)を push しうる
if [ -z "$reason" ] && printf '%s' "$scan" | grep -qE '(^|[[:space:]])--(all|mirror)([[:space:]]|=|$)'; then
  reason="--all / --mirror は保護ブランチを含む全ブランチを push しうる"
fi

# (2) refspec の宛先(コロン右)が保護ブランチ(例: HEAD:release / feature:master / :main(削除))。
#     release-x のような別ブランチを誤検出しないよう、宛先名の直後は境界文字 or 行末に限定する。
if [ -z "$reason" ] && printf '%s' "$scan" | grep -qE ":(refs/heads/)?($PROTECTED_RE)([^[:alnum:]._/-]|$)"; then
  reason="保護ブランチを宛先にした refspec push"
fi

# (3) refspec 無しで保護ブランチ名を直接指定(例: git push origin release)。
#     push 以降のトークンを走査し、オプション(-)でも refspec(:)でもない単独トークンが
#     保護ブランチ名と完全一致する場合のみブロック(myrelease / release-x は対象外)。
if [ -z "$reason" ]; then
  read -ra _toks <<< "$scan"
  _seen_push=0
  for _t in "${_toks[@]}"; do
    if [ "$_seen_push" -eq 0 ]; then
      [ "$_t" = "push" ] && _seen_push=1
      continue
    fi
    case "$_t" in
      -*) continue ;;   # オプションは (4) で処理済み
      *:*) continue ;;  # refspec は (2) で処理済み
      release|master|main) reason="保護ブランチ名を直接指定した push"; break ;;
    esac
  done
fi

# (1) push 先のリポジトリのブランチが保護ブランチ。シェルを模倣して追いかけるのではなく、
#     静的に解析できる単純な形(cd <path> && ... / git [-C <path>] push を && と | で
#     つないだもの)だけを解決し、それ以外の構文は fail-closed でブロックする。
if [ -z "$reason" ]; then
  cwd_json=""
  if command -v jq >/dev/null 2>&1; then
    cwd_json="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
  fi
  base_dir="${cwd_json:-$(pwd)}"

  # 相対パスは実際に cd して pwd で解決する。存在しないパスや、呼び出し元のシェルで
  # 展開されなかった "$VAR" リテラルは、ここで解決失敗(空文字)として扱われる。
  resolve_dir() {
    local from="$1" to="$2"
    case "$to" in
      /*) : ;;
      *) to="$from/$to" ;;
    esac
    ( cd "$to" 2>/dev/null && pwd )
  }

  # トークン列 [seg_start, seg_end) から最初の "git" 呼び出しを解析する。サブコマンドが
  # push なら、その push 自身に --dry-run / -n が付いているかも見て、dry-run push は
  # _push_dirs / _git_dirs のどちらにも積まず _dry_push フラグだけ立てる(実 push だけを
  # 検査対象にするため)。-C はこの呼び出し内でのみ累積し、他のセグメント/呼び出しには
  # 持ち越さない(実際の git と同じ)。
  parse_git_segment() {
    local seg_start="$1" seg_end="$2" base="$3"
    local gi found=0 pre_dash=0
    gi="$seg_start"
    while [ "$gi" -lt "$seg_end" ]; do
      if [ "${_r1_all[$gi]}" = "git" ]; then
        found=1
        break
      fi
      # git より前に来るオプション形式のトークン(env -C <dir> の -C、timeout -k 5 60 の
      # -k 等)は、cwd や実行環境を変えうるのに解釈できないので、後で git が見つかったときに
      # fail-closed でブロックする(NAME=VALUE・数字・env / timeout / nice / nohup / time の
      # ような素の語は - で始まらないので透過する)。git が最終的に見つからない(このセグメント
      # に git 呼び出しが無い)場合は無関係なので、ここでは何もせず found=0 のまま抜ける。
      case "${_r1_all[$gi]}" in
        -*) pre_dash=1 ;;
      esac
      gi=$((gi + 1))
    done
    if [ "$found" -eq 0 ]; then
      return 0
    fi
    if [ "$pre_dash" -eq 1 ]; then
      reason="git 前のラッパオプション"
      reason_is_syntax=1
      return 0
    fi

    local dir="$base" oi sub="" ot carg newdir
    oi=$((gi + 1))
    while [ "$oi" -lt "$seg_end" ] && [ -z "$reason" ]; do
      ot="${_r1_all[$oi]}"
      # サブコマンドに到達する前のリダイレクト由来トークン(">" "2" のような fd 番号等)を
      # サブコマンドと誤認しないよう、ここで検出して fail-closed にする。-c/--config-env が
      # 消費した引数はここに来ないので、この位置に来る数字のみのトークンはリダイレクト由来。
      case "$ot" in
        '>' | '>>' | '<' | '&')
          reason="サブコマンド前のリダイレクト"
          reason_is_syntax=1
          ;;
        [0-9]*)
          case "$ot" in
            *[!0-9]*) : ;;
            *)
              reason="サブコマンド前のリダイレクト"
              reason_is_syntax=1
              ;;
          esac
          ;;
      esac
      if [ -n "$reason" ]; then
        break
      fi
      case "$ot" in
        -C)
          carg="${_r1_all[$((oi + 1))]:-}"
          if [ -z "$carg" ]; then
            reason="push 先のリポジトリを特定できない"
            reason_is_syntax=1
            break
          fi
          newdir="$(resolve_dir "$dir" "$carg" || true)"
          if [ -z "$newdir" ]; then
            reason="push 先のリポジトリを特定できない"
            reason_is_syntax=1
            break
          fi
          dir="$newdir"
          oi=$((oi + 2))
          ;;
        -c | --config-env)
          oi=$((oi + 2))
          ;;
        --config-env=*)
          oi=$((oi + 1))
          ;;
        --no-pager | -P | --paginate | -p | --no-replace-objects | \
        --literal-pathspecs | --glob-pathspecs | --noglob-pathspecs | \
        --icase-pathspecs | --no-optional-locks | --no-lazy-fetch | --no-advice)
          oi=$((oi + 1))
          ;;
        -*)
          reason="未対応の git グローバルオプション"
          reason_is_syntax=1
          ;;
        *)
          sub="$ot"
          break
          ;;
      esac
    done
    if [ -n "$reason" ]; then
      return 0
    fi

    if [ "$sub" = "push" ]; then
      local dry=0 di
      di=$((oi + 1))
      while [ "$di" -lt "$seg_end" ]; do
        case "${_r1_all[$di]}" in
          --dry-run | -n) dry=1 ;;
        esac
        di=$((di + 1))
      done
      if [ "$dry" -eq 1 ]; then
        _dry_push=1
      else
        _git_dirs+=("$dir")
        _push_dirs+=("$dir")
      fi
    else
      _git_dirs+=("$dir")
    fi
    return 0
  }

  # Step 0: push トークン(完全一致)が 1 つも無ければ何もしない(prefilter の *git*push* が
  # pushd やファイル名中の "push" に反応しただけ。トークン化後のトークンで見るので
  # "push&&true" のような密着形でも見落とさない)。
  _r1_has_push=0
  for _r1_t in "${_r1_all[@]}"; do
    if [ "$_r1_t" = "push" ]; then
      _r1_has_push=1
      break
    fi
  done

  if [ "$_r1_has_push" -eq 1 ]; then
    # Step 1: 静的に追えない構文は即ブロックする(改行(行継続を除く)・; ・||・サブシェル・
    # バッククォート・未展開のシェル変数・単独の &(バックグラウンド))。別シェル/eval/source
    # 経由の検査は tokenize 直後に最優先で済ませてある。
    case "$_scan_nl" in
      *$'\n'* | *';'* | *'||'* | *'('* | *')'* | *'{'* | *'}'* | *'`'*)
        reason="push 先のリポジトリを特定できない構文"
        reason_is_syntax=1
        ;;
    esac
    if [ -z "$reason" ]; then
      case "$scan" in
        *'$'*)
          reason="未展開のシェル変数を含む"
          reason_is_syntax=1
          ;;
      esac
    fi
    if [ -z "$reason" ]; then
      _r1_amp="${scan//&&/}"
      _r1_amp="${_r1_amp//>&/}"
      _r1_amp="${_r1_amp//<&/}"
      _r1_amp="${_r1_amp//&>/}"
      case "$_r1_amp" in
        *'&'*)
          reason="push 先のリポジトリを特定できない構文"
          reason_is_syntax=1
          ;;
      esac
    fi
    # Step 2: "&&" で chain に分割し、shell_dir(cd で更新)を引き継ぎながら順に走査する。
    # 各 chain はさらに "|" でセグメントに分割し、セグメントごとに git 呼び出しを解析する
    # (pipeline の各コマンドは並行実行されるため、-C はセグメントをまたいで累積しない)。
    if [ -z "$reason" ]; then
      shell_dir="$base_dir"
      _push_dirs=()
      _git_dirs=()
      _dry_push=0
      _r1_chain_start=0
      _r1_i=0
      while [ -z "$reason" ] && [ "$_r1_i" -le "$_r1_n" ]; do
        if [ "$_r1_i" -eq "$_r1_n" ] || [ "${_r1_all[$_r1_i]}" = "&&" ]; then
          _r1_clen=$((_r1_i - _r1_chain_start))
          if [ "$_r1_clen" -gt 0 ]; then
            _r1_first="${_r1_all[$_r1_chain_start]}"
            _r1_pipe_count=0
            _r1_j="$_r1_chain_start"
            while [ "$_r1_j" -lt "$_r1_i" ]; do
              if [ "${_r1_all[$_r1_j]}" = "|" ]; then
                _r1_pipe_count=$((_r1_pipe_count + 1))
              fi
              _r1_j=$((_r1_j + 1))
            done

            if [ "$_r1_pipe_count" -eq 0 ]; then
              if [ "$_r1_first" = "cd" ]; then
                if [ "$_r1_clen" -eq 1 ]; then
                  shell_dir="$HOME"
                else
                  _r1_nxt="${_r1_all[$((_r1_chain_start + 1))]}"
                  case "$_r1_nxt" in
                    -*)
                      reason="push 先のリポジトリを特定できない構文"
                      reason_is_syntax=1
                      ;;
                    *'~'*)
                      reason="push 先のリポジトリを特定できない構文"
                      reason_is_syntax=1
                      ;;
                    *)
                      _r1_newdir="$(resolve_dir "$shell_dir" "$_r1_nxt" || true)"
                      if [ -z "$_r1_newdir" ]; then
                        reason="push 先のリポジトリを特定できない"
                        reason_is_syntax=1
                      else
                        shell_dir="$_r1_newdir"
                      fi
                      ;;
                  esac
                fi
              else
                parse_git_segment "$_r1_chain_start" "$_r1_i" "$shell_dir"
              fi
            else
              # パイプライン: セグメントごとに解析する。cwd はどのセグメントも親シェルへ
              # 引き継がれないため shell_dir は更新しない。先頭が cd のセグメントは
              # サブシェルで実行される cd なので即ブロックする。
              _r1_seg_start="$_r1_chain_start"
              _r1_j="$_r1_chain_start"
              while [ -z "$reason" ] && [ "$_r1_j" -le "$_r1_i" ]; do
                if [ "$_r1_j" -eq "$_r1_i" ] || [ "${_r1_all[$_r1_j]}" = "|" ]; then
                  if [ "$_r1_j" -gt "$_r1_seg_start" ]; then
                    if [ "${_r1_all[$_r1_seg_start]}" = "cd" ]; then
                      reason="push 先のリポジトリを特定できない構文"
                      reason_is_syntax=1
                    else
                      parse_git_segment "$_r1_seg_start" "$_r1_j" "$shell_dir"
                    fi
                  fi
                  _r1_seg_start=$((_r1_j + 1))
                fi
                _r1_j=$((_r1_j + 1))
              done
            fi
          fi
          _r1_chain_start=$((_r1_i + 1))
        fi
        _r1_i=$((_r1_i + 1))
      done
    fi

    # Step 3: 判定。push 呼び出しが見つかっていればそれぞれの解決先ディレクトリのブランチを
    # 見る(1 つでも保護ブランチならブロック)。push 呼び出しが 1 つも見つからず dry-run
    # push だけがあった場合は判定せず許可する。push 呼び出しとして解決できなかった(push
    # トークンはあるが git push 呼び出しと認識できなかった。例: echo push && git status /
    # cat .gitconfig | grep push)場合は、Step 2 で解析できた各 git 呼び出しの解決先
    # (_git_dirs)と走査終了時点の shell_dir をすべて見て判定する(git トークンが
    # 無ければ _git_dirs は空になり、shell_dir だけを見る。fail-closed)。
    if [ -z "$reason" ]; then
      if [ "${#_push_dirs[@]}" -gt 0 ]; then
        for _r1_pd in "${_push_dirs[@]}"; do
          _r1_branch="$(git -C "$_r1_pd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
          if [ -z "$_r1_branch" ]; then
            reason="push 先のリポジトリを特定できない"
            reason_is_syntax=1
            break
          fi
          case "$_r1_branch" in
            release | master | main)
              reason="push 先のブランチ '$_r1_branch' が保護ブランチ"
              break
              ;;
          esac
        done
      elif [ "$_dry_push" -eq 1 ]; then
        : # dry-run の push しか無いので判定せず許可する
      else
        _git_dirs+=("$shell_dir")
        for _r1_pd in "${_git_dirs[@]}"; do
          _r1_branch="$(git -C "$_r1_pd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
          if [ -z "$_r1_branch" ]; then
            reason="push 先のリポジトリを特定できない"
            reason_is_syntax=1
            break
          fi
          case "$_r1_branch" in
            release | master | main)
              reason="push 先のブランチ '$_r1_branch' が保護ブランチ"
              break
              ;;
          esac
        done
      fi
    fi
  fi
fi

if [ -n "$reason" ]; then
  {
    echo "BLOCKED: 保護ブランチ(release/master/main)を更新する push は禁止です。"
    echo "理由: $reason。"
    echo "feature ブランチを切って PR を作成してください(例: git switch -c feat/xxx)。"
    echo "意図的に push する必要がある場合は、Claude ではなく手動ターミナルで実行してください。"
    if [ -n "$reason_is_syntax" ]; then
      echo "単純な形(git -C <path> push / cd <path> && git push。; || ( ) \$VAR や別シェル経由は不可)で書き直してください。"
    fi
  } >&2
  exit 2
fi
exit 0
