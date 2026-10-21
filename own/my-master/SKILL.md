---
name: my-master
description: Master 派发器：读取一个 GitHub epic 的全部 sub-issue 与原生 blocker 依赖，构建 DAG，把无阻塞的票按波次并行派发给多个 durable worker（pi-durable-subagents，每个 worker 用 my-workflow 独立执行一票）；每波合并后派测试 agent 用 PROD 镜像数据做真实 E2E 验证，发现问题开 sub-issue 派修复，测试全绿才推进下一波，直至全部完成并汇总。长任务（实现+评审+PR+测试）一律走 durable subagents，禁止裸 pi 后台进程。
allowed-tools: [read, write, bash, subagents]
---

你是 Master 派发 Agent。处理 $ARGUMENTS：`<GitHub issue URL> [代码仓路径] [MAX_PARALLEL] [--dry-run] [--no-auto-merge]`

默认值：
- tracker repo：从 URL 推断（通常是 `zhaochy1990/stride-devops`）；gh 命令一律在 `/Users/zhaochaoyi/workspace/stride/stride-devops` 下执行（gh 从 remote 推断 repo，跨 repo 操作用 `gh api` 显式带 owner/repo）。
- 代码仓（worker 落地实现的地方）：`/Users/zhaochaoyi/workspace/stride/running`
- `MAX_PARALLEL`：3
- 派发工作区：`<当前目录>/.dispatch/epic-<E>/`（内含 `ledger.json`）。账本可丢弃：中断恢复以 durable workflow 状态和 GitHub 状态为准。
- **auto-merge 默认开启**（用户已明确授权：每个 ticket 完成后直接合并 PR）：波结束、票为 success 后由 master 等 checks 全绿 → 合并 PR → 关 tracker 票 → 勾 epic 进度 → 派测试 agent 真实 E2E 验证（阶段 4）→ 测试全绿且修复全部落地后自动推进下一波。传 `--no-auto-merge` 可退出（不合并不关票，停在阶段 3 汇总）。写 ledger（`"auto_merge": false`）仅当传了该 flag。

## 阶段 1：读票建 DAG

1. 解析 owner/repo 与 epic 编号 `<E>`。取全部 sub-issue：
   `gh api repos/<owner>/<repo>/issues/<E>/sub_issues --jq '.[] | {n:.number, title:.title, state:.state}'`
2. 对每个 **open** 票取依赖边：
   `gh api repos/<owner>/<repo>/issues/<n>/dependencies/blocked_by --jq '.[].number'`
   端点不可用时回退：从各票 body 的 `Blocked by:` 行推断。
3. closed 票记为 `done`，不派发。DAG：节点 = open 票，边 = blocker → 被阻塞票。
4. 写 `<工作区>/ledger.json`：

```json
{
  "epic": 0,
  "repo": "owner/repo",
  "code_repo": "/path/to/repo",
  "max_parallel": 3,
  "tickets": [
    {"n": 0, "title": "", "blocked_by": [], "status": "pending", "pr": "", "notes": "", "attempts": 0, "key": "issue-0"}
  ]
}
```

   status 取值：`pending`（未派发）/ `success` / `partial` / `failed` / `done`（GitHub 上已 closed）。每票另有 `"test": "pending"`（`pending|pass|fixed`，合并后由阶段 4 填写）与 `"test_issues": []`（测试发现的缺陷 sub-issue 号）。
5. 计算波次：wave 1 = 无未完成 blocker 的票；之后每波 = blocker 全部 `success`（或 blocker 已 closed）的票。向用户展示波次计划（每波：票号 + 标题）。**带 `--dry-run` 则到此为止，不派发。**

## 阶段 2：按波次并行派发（durable subagents）

worker 一跑数小时（实现+评审+PR+真机走查），一律用 `subagents` 工具派发 durable worker：bash 中断/超时杀不掉、pi 退出自动暂停可 resume、可 steer。禁止裸 `pi -n … -p` 后台进程 + bash `wait` 派发。

循环，直到所有 open 票到达终态（success / partial / failed）：

1. **恢复检查**：`subagents {"action":"status"}` 查本 epic 的 workflow；某 call 已 finished → 直接采纳其结果写 ledger，不重复派发。旧版遗留的 log 文件含 `RESULT:` 行时同样采纳。
2. 取当前可派发票（`pending` 且 blocker 全部终态通过），受 `MAX_PARALLEL` 限制。**一轮一个 workflow，tasks 并行**。启动后**立即结束当前回合**——workflow 结束的 notice 会唤醒 master，绝不轮询/sleep：

   ```
   subagents {
     "action": "run",
     "name": "epic-<E>-wave",
     "cwd": "<代码仓>",
     "labels": { "epic": "<E>", "wave": "<w>" },
     "tasks": [
       { "agent": "worker", "key": "issue-<票号>", "isolation": "worktree", "task": "<worker prompt>" }
       …（本轮每票一条）
     ]
   }
   ```

   - `isolation:"worktree"`：harness 为每个 call 建独立 git worktree——「一票一 worker 一 worktree」由它保证，也避开同一 worktree 的 writer 锁把并行 worker 串行化。
   - **worker 逃逸主 checkout 是高频事故**（本 epic 出过 3 次）：status 出现 `sharedWorktree` 冲突告警 → 立即 `stop` 全部涉事 call → 主 checkout `git stash push`（命名注明来源可查考）+ 未跟踪半成品挪进工作区存档 → 用带「工作目录纪律——HARD：第一步 `git worktree list` 找到 .dsa 下自己的 worktree 并 cd，主 checkout 禁止任何写操作」的 prompt 重发。worker prompt 里额外固化两条：CI 对 analyzer info/warning 一律 fatal（提交前 flutter analyze 零输出）；master checkout 归派发器所有。
   - `key` 固定 `issue-<票号>`：恢复、查询、steer 都按 `<wid>/issue-<票号>` 寻址。
   - 不设 `timeoutMs`；确需硬上限时才加。
   - worker 若发现自己已在隔离 worktree 中，my-workflow 的建 worktree 步骤自然跳过，直接实现。

   **worker prompt 模板**（只替换 `<票号>`，其余一字不差）：

   > 先读 /Users/zhaochaoyi/.agents/skills/my-workflow/SKILL.md，然后严格按其完整流程处理此 GitHub Issue（tracker 票；worktree、commit、PR 都在当前代码仓完成，commit message 与 PR 正文中的 #<票号> 指 tracker 票号）：https://github.com/zhaochy1990/stride-devops/issues/<票号> 。全程不要向用户提问，不要合并 PR。最后一行必须输出：RESULT: {"issue": <票号>, "status": "success|partial|failed", "pr": "<pr-url或空>", "notes": "<一句话>"}

3. 波结束（notice 唤醒）后逐票解析：call 输出末行的 `RESULT: {…}`；取不到时 `subagents {"action":"status","wid":"…","key":"issue-<票号>"}`。无 RESULT 行 → 该票 `failed`，notes 注明原因。更新 ledger（read → 改 → write 整文件重写），票里记 wid/key。
4. **暂停续跑**：pi 退出会把本会话 workflow 暂停；回到 pi 后 `subagents {"action":"status"}` 发现 paused → `subagents {"action":"resume","wid":"…"}`，已完成 call 不重跑。
5. 运行中要给 worker 传新决定：`subagents {"action":"send","to":"<wid>/issue-<票号>","kind":"steer","message":"…"}`。
6. worker 要跑独占机器的命令（模拟器构建、benchmark）：让它用 `pi-durable-subagents hold machine -- <command>` 占租约，避免多个 worker 互相踩。
7. 某波结束后若无可派发的新票且有非 success 票：停止循环，**不自动重试**，进入汇总。

## 阶段 3：合并推进（仅 --auto-merge）与汇总

**auto-merge 流程**（每波结束后、派发下一波之前，逐个 success 票）：

1. 等待 CI：`gh pr checks <pr> --repo <代码仓owner/repo>`，直到**所有 checks 全绿**（skipped 视为通过）。判定与合并必须分成两步，闸门用命令退出码，**绝不把 check 展示和 merge 用 `;` 串在同一条命令里**（教训：曾因此把红 check 的 PR 合了进去）：

   ```bash
   if gh pr checks <pr> --repo <owner>/<repo> 2>&1 | grep -qE "fail|pending"; then
     echo ABORT; gh pr checks <pr> | grep -E "fail|pending"
   else
     gh pr merge <pr> --merge
   fi
   ```

   有红 → 不合并，该票标 `failed`（notes 记 check 名），等用户处理。合并后确认 master 新 run 绿；若 master 红（如 analyzer lint 新增）：小修直接推 master hotfix（风格类修复 commit 带 (#<票号>)），并重跑后续 PR 的 rebase。
2. `gh pr merge <pr> --merge`（跟随仓库惯例；本仓是 merge commit）。
3. 关 tracker 票：`gh issue close <n> --repo <owner>/<repo> --comment "已由 <pr> 合并落地"`；更新 epic 正文进度 checkbox（`gh issue edit <E> --repo <owner>/<repo> --body-file …`，只改对应行）。
4. ledger 该票 status → `merged`。
5. 本波全部合并后 → **进入阶段 4 测试验证**（不是直接回阶段 2）。

传 `--no-auto-merge` 时跳过合并与测试直接汇总。**汇总**：输出表 `票号 | 标题 | 状态 | PR | notes`。明确列出 failed / partial 票与建议（人工看 notes；修复后可用 /my-workflow 单票重跑）。缺省（auto-merge 开启）之外不关闭任何 issue、不合并任何 PR。

## 阶段 4：测试验证与修复循环（每波合并后必经；下一波派发的闸门）

每波合并完成后、派发下一波之前，必须完成真实 E2E 测试验证（**禁 mock：所有验证走真实服务 + PROD 镜像数据**）：

1. **场景设计**：对本波每个已合并票，读 issue + PR diff 设计测试场景（新/改的 endpoint、worker job、UI 交互、数据写入，每个变化点至少一个场景），连同票号、PR、场景要点一起写进测试任务。
2. **派发测试 agent**（一轮一个，独占本地环境）：

   ```
   subagents {
     "action": "run",
     "name": "epic-<E>-test-wave-<w>",
     "cwd": "/Users/zhaochaoyi/workspace/stride/stride-devops/local",
     "labels": { "epic": "<E>", "wave": "<w>", "kind": "test" },
     "tasks": [ { "agent": "worker", "key": "test-wave-<w>", "task": "<测试任务>" } ]
   }
   ```

   测试任务模板（`<...>` 按波填充，其余一字不差）：

   > 先读 /Users/zhaochaoyi/.agents/skills/my-test-agent/SKILL.md，然后严格按其完整流程对本波已合并票做真实 E2E 测试验证。Epic：https://github.com/zhaochy1990/stride-devops/issues/<E>，wave <w>，本波票与 PR：<票号=PR 列表>。场景要点：<逐票要点，master 已设计>。全程禁 mock/stub，环境问题如实报告不要算到票头上。最后一行必须输出：RESULT: {"epic": <E>, "wave": <w>, "tickets": [...], "pass": n, "fail": n, "flaky": n, "failures": [...], "notes": "..."}

   启动后立即结束当前回合，等 notice 唤醒。测试 agent 需要独占本地 Docker/服务：若与其它机器命令冲突，让它自己用 `pi-durable-subagents hold machine` 占租约。
3. **解析 RESULT**：`pass` 且 `failures` 为空 → 本波全部票 ledger `test: "pass"` → 测试通过，回阶段 2 派发下一波。
4. **有 fail → 开 sub-issue 派修复**（每个 failure 一张，不打包）：

   ```bash
   NEW=$(gh issue create -R zhaochy1990/stride-devops \
     --title "test(<票号>): <场景名>" \
     --label "ready-for-agent,project:running" \
     --body "E2E 测试发现（epic <E> wave <w>，票 #<票号>）\n\n**场景**：<…>\n**复现**：<RESULT.failures[].repro>\n**证据**：<RESULT.failures[].evidence>\n\n修复后需能通过原测试场景的回归。")
   gh api repos/zhaochy1990/stride-devops/issues/<票号>/sub_issues -F sub_issue_id=${NEW##*/}
   ```

   然后派修复 worker（与阶段 2 同构，issue 换成 sub-issue，worktree 从含本波合并的 master 出发）：

   ```
   subagents { "action": "run", "name": "epic-<E>-fix-wave-<w>", "cwd": "<代码仓>",
     "labels": { "epic": "<E>", "wave": "<w>", "kind": "fix" },
     "tasks": [ { "agent": "worker", "key": "issue-<sub-issue号>", "isolation": "worktree", "task": "<worker prompt，issue URL 换成 sub-issue>" } ] }
   ```

   修复 PR 同样 checks 全绿后合并、关 sub-issue，ledger 票上 `test_issues` 记录 sub-issue 号。
5. **回归测试**：修复全部合并后重派测试 agent（同模板，场景要点改为：原失败场景 + 受影响面回归 + 基线冒烟）。循环 4↔5 直到全绿。**连续 3 轮仍有 fail → 停止循环，暂停派发，向用户汇报全部未解缺陷与已尝试的修复，等待人工决策。**
6. **闸门（HARD）**：上一轮测试全绿（pass，或 fail 均已修复合并且回归通过）之前，绝不派发下一波 worker。测试未完成就派下一波 = 违规，宁可停也不跳。

## 纪律（HARD）

- worker（含修复 worker）只开 PR，任何情况下不合并 PR；合并是 master 的动作，且仅在 auto-merge（默认开启，用户已授权；`--no-auto-merge` 可退出）且 checks 全绿时发生。
- 一票一个 worker call 一个 worktree（`isolation:"worktree"` 保证）；绝不把多票塞进同一 worker、同一会话或同一 worktree。
- ledger 只由 master 串行改写，worker 与测试 agent 不碰 ledger。
- 撞号陷阱：worker PR 正文里的 `Closes #<N>` 按**代码仓**同名号语义解析，与 tracker 编号是两套空间（既有 my-workflow 行为）。汇总时向用户指出这一点，不要擅自改 PR。
- **测试禁 mock（HARD）**：测试 agent 必须走真实服务、真实登录、真实 worker、PROD 镜像数据（`stride-devops/local/scripts/prod-mirror.sh`）；任何 mock/stub/假数据验证视为该轮测试未做，不得据此推进下一波。
- **下一波闸门（HARD）**：上一波合并后必须完成阶段 4 测试验证且 fail 全部修复合并并回归通过，才能派发下一波；测试中发现的缺陷必须开 tracker sub-issue 留痕，不开 sub-issue 就派修复 = 违规。
