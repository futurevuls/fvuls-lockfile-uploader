@AGENTS.md

## Claude Code 固有

- skill: `/commit`(commit 前チェック + メッセージ生成)/ `/review-pr`(並列セルフレビュー)/ `/address-review`(レビュー指摘対応)/ `/pr-describe`。
- `.claude/settings.json` の PreToolUse hook が、main(と release / master)を更新する Claude の push をブロックする。人間が手動で実行する push は止めない。
