# otter 测试结果
执行时间：2026-09-19 19:40:28

| ID | 状态 | 备注 |
|----|------|------|
| T01 | PASS | no args -> exit 2 + usage |
| T02 | PASS | -h prints help |
| T03 | PASS | -c + -ks -> exit 2 |
| T04 | PASS | non-whitelist -> exit 2 |
| T05 | PASS | sanitize |
| T06 | PASS | session+window with 3 panes |
| T07 | PASS | left pane runs claude/node (claude) |
| T08 | PASS | nvim window present |
| T09 | PASS | lazygit window present |
| T10 | PASS | no lazygit window in non-git dir |
| T11 | PASS | window count stable (3) |
| T12 | PASS | claude window rebuilt with 3 panes |
| T13 | PASS | session killed, exit 0 |
| T14 | PASS | ks nonexistent -> exit 0 + not found |
| T15 | PASS | install symlink ok |
| T16 | PASS | reinstall replaces link |
| T17 | PASS | uninstall removes link |
| T18 | PASS | uninstall idempotent |
| T19 | PASS | missing claude -> exit 3 |
| T20 | PASS | missing tmux -> exit 3 |
| T21 | PASS | right-top pane runs shell (zsh), not yazi |
| T22 | PASS | default session name = basename(PWD) |
| T23 | PASS | -ks no value -> exit 2 |
| T24 | PASS | -s without -c -> exit 2 |
| T25 | PASS | -s + -ks -> exit 2 |

汇总：Total 25 / Pass 25 / Fail 0 / Skip 0
