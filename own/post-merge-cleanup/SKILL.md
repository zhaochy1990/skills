---
name: post-merge-cleanup
description: PR 合并后的环境清理与收口：校验 PR 已合并，然后停掉为该 ticket 在本地启动的开发服务、删除对应本地 git worktree、删除远程分支、关闭关联 GitHub issue（可选）、把本地 master 快进到最新（本地未提交改动自动 stash 后恢复）。当用户说「PR 合并了，清理一下」「删 worktree」「收尾」「cleanup after merge」，或 my-workflow 产出的 PR 被人工 review 合并后需要善后时使用。
allowed-tools: [bash, read]
---

# PR 合并后清理

用户在网页上人工 review 并合并 PR 之后调用本技能（通常是 my-workflow 的收尾环节）。对一个**已合并的 PR** 执行五项清理；一次调用只处理一个仓库，session 涉及多个仓库（如 running + stride-devops）时分别调用。

输入：$ARGUMENTS = PR 编号 / PR 链接 / 分支名。缺省时取当前 worktree 的分支（`git branch --show-current`）。所有命令在对应仓库目录下执行（主检出或其 worktree 均可）；分支名查不到 PR 时试补 `feat/` 前缀（本工作流的分支命名约定）。

## 唯一的安全门：PR 必须已合并

所有删除动作的授权来自 GitHub 的 PR 状态，而不是任何本地 git 判断：

```bash
gh pr view <PR编号或分支> --json number,state,mergedAt,headRefName,headRefOid,baseRefName,url,closingIssuesReferences
```

- `state` 不是 `MERGED`（OPEN、或 CLOSED 未合并）→ **立即停止**，报告 PR 状态，什么都不要删。
- **本地分支不得领先于已合并的 PR**：`git rev-parse <headRefName>` 必须等于 PR 的 `headRefOid`。不相等说明合并后本地又提交过（squash 合并的分支两者本就不等，这种情况以 PR state=MERGED 为准放行，但要向用户点明是 squash）。普通 merge commit 情况下不相等 → 本地有没进 PR 的提交，停下该分支的 worktree/分支删除，列给用户决定。
- 记下 `headRefName`（要删的分支）和 `baseRefName`（要更新的本地分支，本工作流固定为 master；万一不是 master，下文 master 全部替换为该分支）。
- 不要改用 `git branch --merged origin/master` 之类的本地判断：本仓库 merge commit 和 squash 合并都有历史，squash 之后分支 tip 不是 master 的祖先，本地判断会误判。
- `headRefName` 等于 master/base 分支本身 → 跳过第 2、3 步（没有分支可删）。

各清理步骤尽量独立：某一步失败或被安全检查拦下时，报告原因并继续其余步骤，最后汇总时标出未完成项。唯一例外：第 3 步（停服务）必须先于第 4 步（删 worktree）执行——定位服务的依据是进程命令行/工作目录里的 worktree 路径，目录删掉就找不到了。

## 第 1 步：关联 issue 收口（可选，没有就跳过）

ticket 链接不一定写在 PR 正文里（my-workflow 的输入本身就是 ticket 链接，PR 描述可能没带 `Closes #n`），按可靠性依次从三个来源找，结果按 `owner/repo#number` 合并去重：

**来源 1：本会话历史（最可靠）。** 本技能通常在开发这个 PR 的同一个会话里被调用（my-workflow 开发 → 用户网页 review 合并 → 回来说「清理一下」）。回看对话：my-workflow 调用时的 ticket 链接/编号（$ARGUMENTS）在开头，阶段 5 汇报里还有 PR 编号，直接取用。历史里确实没有就不要猜，走来源 2。

**来源 2：PR 的关闭引用。** GitHub 自己解析的关闭关键字（`Closes/Fixes/Resolves #n`，支持跨仓库）：

```bash
gh pr view <num> --json closingIssuesReferences \
  -q '.closingIssuesReferences[] | "\(.repository.owner.login)/\(.repository.name)#\(.number)"'
```

**来源 3：关键词搜索（兜底，必须用户确认）。** 前两个来源都空、但用户表示确实有 ticket 时，拿 PR 标题/分支名的关键词搜 ticket 仓库（ticket 惯例开在 stride-devops），把候选列给用户确认后才动手，不要自动关：

```bash
gh issue list -R zhaochy1990/stride-devops --search "<关键词>" --state open --json number,title,url
```

三个来源都没有 → 报告「无关联 issue」，正常继续。

对找到的每个 issue 查状态（`gh issue view <n> -R <owner/repo> --json state`）：

- OPEN → 关闭并留痕：`gh issue close <n> -R <owner/repo> -c "通过已合并 PR #<num> 收口"`
- 已 CLOSED（PR 合并时被自动关闭）→ 报告「已关闭」，不要重复操作

## 第 2 步：删除远程分支

```bash
git ls-remote --heads origin <headRefName>   # 先确认还存在
git push origin --delete <headRefName>
```

`ls-remote` 无输出说明网页端合并时已删过 → 跳过并报告。

## 第 3 步：关掉为这个 ticket 在本地启动的服务

开发阶段常在 worktree 里起过本地服务（API、前端 dev server、e2e 栈等），合并后它们还挂着。必须在删 worktree **之前**做，从两个角度找：

```bash
# ① 命令行里带 worktree 路径的进程（node/vite/脚本等）
ps ax -o pid=,command= | grep -F "<worktree绝对路径>" | grep -v grep

# ② 工作目录落在 worktree 里的进程（go run 的编译产物在临时目录，路径不在命令行里）
lsof -F p +d "<worktree路径>"
```

两处结果合并去重（排除本次清理自身），逐个确认是开发服务再动手：

- 匹配必须用**完整绝对路径**。像 `.worktrees/` 这种宽泛模式会命中其他项目的 worktree 进程（本机常有多个项目同时挂着 worktree 服务），有误杀风险——实测就扫到过别的项目的一串 java 服务。

- 先 `kill <pid>`，等 2 秒，仍存活再 `kill -9 <pid>`。
- 只杀明确属于这个 worktree/ticket 的进程。共享基础设施**不要动**——本地 MySQL（3308）、常驻 docker 数据库、微信开发者工具这类不是某个 ticket 的附属品；拿不准的进程列出来交给用户决定。
- 本 session 明显为这个 ticket 起过、但和 worktree 路径无关的服务（如 `docker compose` 起的栈），凭 session 记忆定位后 `docker compose down`；定位不到就报告跳过。
- worktree 不存在（已被清掉）→ 跳过①②，只凭 session 记忆处理。
- 没找到任何进程 → 报告「无残留服务」，正常继续。

## 第 4 步：删除本地 worktree 和本地分支

worktree 目录名和分支名**不一致**（如 `.worktrees/race-strategy` ↔ 分支 `feat/race-strategy`），必须按分支名反查：

```bash
git worktree list --porcelain | awk -v b="refs/heads/<headRefName>" '$1=="worktree"{p=$2} $1=="branch"&&$2==b{print p}'
```

- 找不到 → 本地本来就没有这个 worktree，跳过。
- 找到后先查**已跟踪文件**是否有未提交改动：

```bash
git -C <worktree路径> status --porcelain --untracked-files=no
```

- 有输出 → **停下这一步**，把改动列给用户决定。已合并分支上还有未提交的已跟踪改动，可能是没进 PR 的工作，删掉就没了。
- 无输出 → 构建产物（node_modules、软链、编译出的 .js）属于未跟踪文件，不算障碍，可以删：

```bash
git worktree remove --force <worktree路径>   # --force 只为越过未跟踪产物，已跟踪改动已在上面拦住
git branch -D <headRefName>
```

用 `-D` 不用 `-d`：squash 合并的分支 tip 不在 master 历史里，`-d` 会拒绝；删除授权来自安全门的 MERGED 校验。必须先删 worktree 再删分支——分支还被 worktree 检出时删不掉。

## 第 5 步：更新本地 master（保护本地未提交改动）

master 检出在主仓库目录（`git worktree list` 中 branch 为 master 的那个，通常就是仓库根）。本地 master 常有未提交改动（小程序经常直接在 master 上改），必须 stash → 快进 → 恢复：

```bash
main=<主检出路径>
git -C "$main" status --porcelain                # 有输出才需要 stash
git -C "$main" stash push -u -m "post-merge-cleanup autostash"
git -C "$main" fetch origin
git -C "$main" merge --ff-only origin/master
git -C "$main" stash pop                          # 之前 stash 过才执行
```

- master 没被任何 worktree 检出（罕见）→ 直接 `git fetch origin master:master` 更新引用即可。
- `merge --ff-only` 失败 → 本地 master 有自己的提交（与远端分叉），**停止本步并报告**，绝不自动 rebase/merge，交给用户决定。
- `stash pop` 冲突 → stash 条目不会丢（pop 冲突时不 drop），报告冲突文件和 `git stash list`，交给用户处理。

## 批量模式（一次清理多个已合并的 worktree）

用户要求清一圈遗留 worktree 时：先用一次调用拿到全部 PR 状态再对齐筛选，不要逐分支查：

```bash
gh pr list --state all --limit 300 --json number,state,headRefName,headRefOid,mergedAt
git worktree list   # 本地分支对齐 headRefName，安全门规则逐分支照常适用
```

差异点：第 5 步（更新 master）只在全部处理完后**执行一次**，不要每个 PR 跑一遍 stash/快进/pop。

## 汇报

每步一行，全部动作一目了然：

```
PR #523（feat/my-races-pb）清理完成：
- 关联 issue running#389：已关闭（通过 PR 自动关闭 / 手动关闭 / 无关联 issue）
- 远程分支 feat/my-races-pb：已删除 / 网页端已删，跳过
- 本地服务：已停 api(8082) pid 1234、vite(5173) pid 5678 / 无残留
- worktree .worktrees/my-races-pb：已删除（含本地分支）
- master：cb32228f → a1b2c3d，本地改动已 stash 恢复 / 本地无改动
```
