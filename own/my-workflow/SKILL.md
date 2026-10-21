---
name: my-workflow
description: 基于 GitHub Issue 的端到端交付工作流：worktree 隔离实现、双 Sub-agent 评审修复、创建 PR、监控 CI 全绿后自动 squash 合并、跟踪 master 的 Release 管线拿到发布版本，最后把改动总结与版本号更新到当前 iteration 的 Release Note issue。
allowed-tools: [read, edit, bash, subagent]
---

你现在是一个高级工作流编排器。请处理用户输入的 GitHub Issue 链接：$ARGUMENTS

固定拓扑（本工作流依赖，直接使用勿再探索）：

- 代码仓：`zhaochy1990/running`（默认分支 **master**；push 到 master 自动触发 `release.yml`，按 `.github/release-packages.json` 的路径检测变更 artifact，版本号是 CalVer，记录在仓根 `versions.json`）
- ticket 与 Release Note issue 仓：`zhaochy1990/stride-devops`（该仓无 release 管线）
- GitHub Project：**STRIDE**（编号 2，owner `zhaochy1990`，id `PVT_kwHOAKU1yc4BfJDQ`），有 Iteration 字段（当前有效迭代形如 `2026/10`）
- 合并方式一律 **merge commit**（`gh pr merge --merge`，running master 历史全为此形态，勿用 squash）；分支命名 `feat/<slug>`；等待 CI/release 用轮询接力，单条 Bash 调用不要阻塞超过 ~5 分钟

请严格按照以下顺序执行此固定工作流：

### 阶段 1：环境准备 (using-git-worktrees)
1. 使用 `using-git-worktrees` 技能，根据传入的 GitHub Issue 链接 ($ARGUMENTS) 创建一个新的独立 git worktree，并切换至该环境中。

### 阶段 2：功能实现 (implement)
2. 在该新 worktree 中，全面分析 Issue 需求。
3. 使用 `implement` 技能进行代码编写与实现。

### 阶段 3：并行代码评审 (Parallel Review)
4. 代码实现完成后，创建两个独立的、并行的并发子智能体（sub-agents）：
   - **Sub-agent A (Reviewer 1)**：为其加载 `code-review` 技能，对当前修改的代码进行全面审查，提出改进意见。
   - **Sub-agent B (Reviewer 2)**：对同一份 diff 做专项审查，只盯 **over-engineering**：不必要的抽象、用不上的扩展点、超前泛化、可删的死代码。不评风格，只提「可以更简单」的具体建议。
5. 等待两个 Sub-agents 运行完毕并收集它们的评审报告。

### 阶段 4：反馈修复 (Fix)
6. 汇总 Sub-agent A 和 Sub-agent B 的评审意见。
7. 针对评审中指出的缺陷和优化点，先进行评估是否需要修复，如果需要，在主环境中重新对代码进行 `fix` 和完善。
8. 向用户简要汇报评审意见的评估与处理结果。

### 阶段 5：提交并创建 PR（必须执行，不可跳过）
9. 从 $ARGUMENTS 的 Issue URL 中提取 Issue 编号 `<N>`。
10. 在 worktree 中 `git add` 并提交：commit message 遵循约定式提交 `type(scope): description (#<N>)`，标题末尾带上 `(#<N>)` 使 commit 关联 Issue。
11. 推送分支并创建 PR：`gh pr create --base master`，PR 正文包含 **全限定** `Closes zhaochy1990/stride-devops#<N>`（ticket 在 devops 仓，纯 `Closes #N` 不跨仓解析、关不了票；实现完成时）或 `Refs zhaochy1990/stride-devops#<N>`（部分完成时），以及实现摘要和评审修复说明。
12. 创建 PR 后用 `gh pr checks <pr-url>` 确认 CI 已触发（退出码 8 = checks 还没出现，稍等重查即可）。

### 阶段 6：CI 监控与自动合并（本工作流已获授权直接合并，无需再问用户）
13. 监控 CI 至出结果：`gh pr checks <pr-url> --watch --interval 30`（退出码 0 = 全绿）。单次调用超时就改用轮询接力（`sleep 30` + `gh pr checks <pr-url>`），继续等，不要放弃。
14. **全绿后**：先确认 `gh pr view <pr> --json mergeable,mergeStateStatus` 中 `mergeStateStatus` 不是 `DIRTY`，然后直接合并：
    `gh pr merge <pr> --merge --delete-branch`
    （merge commit + 全限定 `Closes` 会在合并瞬间自动关掉 devops 的票，已多次实证。）
15. **CI 失败**：`gh run view <失败的run> --log-failed` 定位原因 → 回 worktree 修复 → push → 回到第 13 步重新监控。最多修复 **2 轮**；仍失败则**停止、不合并**，向用户汇报失败原因与 PR 链接，工作流到此结束（不执行阶段 7-9）。
16. **合并冲突（DIRTY）**：worktree 里 `git fetch origin && git rebase origin/master` → 解决冲突 → push（`--force-with-lease`）→ 回到第 13 步。
17. 跨仓双 PR 场景（running + stride-devops 各一个）：对每个 PR 逐个走完本阶段；阶段 7 的 release 监控只针对 **running 仓**的 PR。

### 阶段 7：Release 管线监控（仅 running 仓 PR；devops-only PR 跳过本阶段，版本记「—」）
18. 取合并提交：`gh pr view <pr> -R zhaochy1990/running --json mergeCommit -q .mergeCommit.oid`。
19. 找到本次触发的 release run（只认 merge SHA 那个；`commit-versions` 推的版本提交带 `[skip ci]`，即便产生了后续 run 也别跟错）：
    `gh run list -R zhaochy1990/running --workflow release.yml --branch master --limit 10 --json databaseId,headSha,status,event` 中 `headSha == mergeCommit` 且 `event == push` 的行。刚合并时可能还没出现，`sleep` 后重查。
20. 轮询至完成：`gh run view <id> -R zhaochy1990/running --json status,conclusion,jobs` + `sleep 30` 接力等待（release 一般 ≤30 分钟；超 60 分钟视为异常，停下汇报）。
21. **成功后提取版本号**：
    ```bash
    git -C <running仓> fetch origin master
    git -C <running仓> show <mergeSHA>:versions.json    # 合并前
    git -C <running仓> show origin/master:versions.json # release 后（含 commit-versions 的提交）
    ```
    对比两份 JSON，值变了的 key 就是本次发布的 artifact + 版本（可能多个，如 `stride-api 2026.10.29 + stride-worker 2026.10.29`）。无差异 = 本次改动不在 release-packages 路径内，未发布镜像，版本记「—」。
22. **失败**：从 jobs 里找出失败 job，记录 run 链接，版本记「发布失败」，仍继续阶段 8（表格如实记录），并在最终汇报里置顶提示。
23. release 成功时会在 stride-devops 开出 pin-images 部署 PR（把版本 pin 进 versions.env）。那是**生产发布审批门，绝不自动合并**，只在 Release Note 的上线说明里附上它的链接。

### 阶段 8：更新当前 iteration 的 Release Note issue
24. 确定当前 iteration：
    ```bash
    gh api graphql -f query='query{ node(id: "PVT_kwHOAKU1yc4BfJDQ") { ... on ProjectV2 { field(name: "Iteration") { ... on ProjectV2IterationField { configuration { iterations { id title startDate duration } } } } } } }' \
      --jq '.data.node.field.configuration.iterations[] | "\(.id) \(.title) \(.startDate) \(.duration)"'
    ```
    取 **startDate ≤ 今天** 的最后一个（duration 天为其跨度，如 `2026/10` 起 2026-10-04）。
25. 找 Release Note issue：`gh issue list -R zhaochy1990/stride-devops --label "Release Note" --state open --json number,title,url`，标题精确等于 `Iteration <iteration名> release note`（如 `Iteration 2026/10 release note`）。
26. **不存在则新建**（label 缺失先建：`gh label create "Release Note" -R zhaochy1990/stride-devops --description "Iteration 发布记录汇总表" --color 0E8A16`，已存在则忽略报错）：
    ```bash
    gh issue create -R zhaochy1990/stride-devops \
      --title "Iteration <iteration名> release note" \
      --label "Release Note" \
      --body-file <(printf '| Issue | Epic | 版本 | 改动内容 | 上线说明 |\n| --- | --- | --- | --- | --- |\n')
    gh project item-add 2 --owner zhaochy1990 --url <issue-url>
    gh project item-edit 2 --owner zhaochy1990 --url <issue-url> --field Iteration --iteration-id <当前迭代id>
    ```
27. 生成表格行（五个字段）：
    - **Issue 链接**：`zhaochy1990/stride-devops#<N>`
    - **Epic 链接**（optional）：查 issue 的 GitHub 原生 sub-issue 父级
      `gh api graphql -f query='query{ repository(owner:"zhaochy1990", name:"stride-devops"){ issue(number: <N>){ parent { number url } } } }'`，没有就留空
    - **版本号**：阶段 7 的结果（多个 artifact 用 ` + ` 连；未发布写 `—`；失败写 `发布失败`）
    - **改动内容**：≤200 字总结，写清做了什么、解决什么问题，给不读代码的人看
    - **上线说明**：是否需要数据迁移（DB schema 变更必须写明）、依赖的服务版本与上线顺序约束（如「小程序须等本后端版本上线后再发」）、新增配置/密钥；无特殊要求写「无迁移，随版本上线」；有 pin-images 部署 PR 附链接
28. 更新正文：`gh issue view <n> -R zhaochy1990/stride-devops --json body` 读出，把行**追加到表格末尾**；若首列已含本 issue（重跑场景）则**替换旧行**；`gh issue edit <n> -R zhaochy1990/stride-devops --body-file` 写回。

### 阶段 9：收尾清理与汇报（仅在 PR 已合并时执行）
29. 调用 `post-merge-cleanup` 技能逐仓清理（其 MERGED 安全门照常生效；跨仓双 PR 分别调用）。
30. 最终汇报（一次讲全）：PR 链接与合并方式、CI 结论、release run 结论、发布版本号、Release Note issue 链接及更新的行。
31. **机器可读结果行（供 Master 派发器解析，必须执行）**：最终输出的最后一行必须是且只能是：

    `RESULT: {"issue": <N>, "status": "success|partial|failed", "pr": "<pr-url 或空>", "release": "<版本串|none|failed>", "notes": "<一句话>"}`
