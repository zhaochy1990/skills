---
name: clean-local-git
description: 清理本地Git分支，切换到master分支并同步最新代码。
---

清理当前session涉及的本地Git分支，切换到master分支，并同步最新代码到本地。

注意，如果当前session使用的是git worktree进行开发，那么就清理当前session的git worktree，并同步最新代码到本地。

注意，当前session可能涉及多个repository的改动，我们清理所有涉及的repository。