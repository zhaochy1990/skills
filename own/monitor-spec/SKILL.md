---
name: monitor-spec
description: 监控 GitHub issue 地图（wayfinder map / epic）下实现票的依赖与进度，并在地图正文维护 Mermaid 实现 DAG（灰=未开工、绿=可开工/进行中、蓝=已完成）；支持每 10 分钟定时刷新。当用户提到 monitor-spec、刷新/更新 DAG、实现进度、看板状态、启动/停止定时监控，即使没有明说 "DAG" 也应使用本 skill。
---

# monitor-spec

把 GitHub 原生 sub-issue 依赖 + 票面状态 + 代码仓线索，合成为地图 issue 正文里的一段 Mermaid DAG，并可挂定时任务周期刷新。

## 默认对象（用户未指定时）

- **地图 issue**：`zhaochy1990/stride-devops#382`（label `project:running`）。gh 命令一律在 `/Users/zhaochaoyi/workspace/stride/stride-devops` 目录下执行（gh 从 remote 推断 repo）。
- **代码仓**：`/Users/zhaochaoyi/workspace/stride/running`（查实现进度线索）。
- 其它项目复用本 skill 时，替换这两个参数即可。

## 状态 → 颜色（固定约定，勿改）

| 票面状态 | 颜色 | classDef |
| --- | --- | --- |
| closed（已完成） | **蓝色** | `fill:#dbeafe,stroke:#93c5fd,color:#1e40af` |
| open 且无阻塞（可开工/进行中，含已指派、有 PR） | **绿色** | `fill:#d9f5e5,stroke:#9adbb8,color:#0a7a45` |
| open 且 blocked_by > 0（未开工，含推迟票） | **灰色** | `fill:#f0f1f4,stroke:#c8cad0,color:#8a8f99` |

进行中的代码线索（提交/PR）不改颜色，写进 DAG 下方「进度注记」一行一条；蓝色只给 closed。

## 刷新流程（手动运行 = 一次完整刷新）

1. **取数据**：
   - `gh issue view 382 --json body --jq .body > /tmp/map_body.md`；
   - `gh api repos/zhaochy1990/stride-devops/issues/382/sub_issues --jq '.[].number'` 得子票号；
   - 逐票 `gh api repos/zhaochy1990/stride-devops/issues/<n> --jq '{n:.number, title:.title, state:.state, assignees:[.assignees[].login], blocked_by:(.issue_dependencies_summary.blocked_by // 0)}'`；
   - 依赖边（谁阻塞谁）：对每个 open 票 `gh api repos/zhaochy1990/stride-devops/issues/<n>/dependencies/blocked_by --jq '.[].number'`（若该端点不可用，回退从地图正文现有 mermaid 边 + 各票 body 的 `Blocked by:` 行推断）。
2. **代码状态**（只对 open 票，closed 票跳过）：在 running 仓 `git log --oneline --since='<票创建日期>' --grep='<n>' -5` 与 `gh pr list --state open --search "<n> in:title"`。**撞号陷阱**：running 仓库自己的 PR/issue 编号与 stride-devops tracker 编号是两套空间（running 恰好存在无关的 PR #390–#395），所以必须加 `--since=<票创建日期>` 并人工核对主题相关，宁缺勿错；有可信结果才写注记，格式如 `#393：PR #501 开启中 · feat/race-detail 3 commits`。
3. **生成 DAG 段**：mermaid `graph LR`，节点 `T<n>["#<n> 标题关键词"]`，边 = blocker → 被阻塞票；`classDef` 按上表三色 + `class` 归类。整段包裹在标记之间（见下），随后是图例与进度注记、末行 `刷新于 <YYYY-MM-DD HH:MM 本地时间>`。
4. **写回**：用标记做整段替换，`gh issue edit 382 --body-file /tmp/map_body_new.md`。**只动标记之间的内容，正文其余部分一字不改。**
5. **汇报**：一句话说明哪些票变色/新增，以及下次刷新时间（若定时在跑）。

## 标记约定（幂等更新的关键）

```text
<!-- monitor-spec:dag:start -->
### 实现依赖 DAG（由 monitor-spec 维护；权威依赖状态以 GitHub 原生 blocker 为准）
<mermaid 代码块>
图例：蓝色=已完成 · 绿色=可开工/进行中 · 灰色=未开工（含 v2 推迟）
<可选进度注记，每行一条>
刷新于 <时间>
<!-- monitor-spec:dag:end -->
```

- 地图正文**已有标记**：替换两个标记之间的全部内容。
- **没有标记**：在 Notes 区「实现票」说明行之后插入整个标记段（首次运行时，先删掉旧的手写 DAG 段——找 `### 实现依赖 DAG` 标题到其图例行——避免两份图并存）。

## 定时监控（用户说「启动监控/每10分钟/开始定时」时）

1. `CronList` 查是否已有标题含 `monitor-spec` 的自动化：有 → 用 `CronUpdate` 确保节奏为每 10 分钟（`*/10 * * * *`）；无 → `CronCreate`：
   - `cron`: `*/10 * * * *`，`recurring`: true
   - `title`: `monitor-spec：每10分钟刷新赛事中心实现 DAG`
   - `prompt`: 下面「定时任务 prompt」全文，一字不差。
2. 用户说「停止监控」：`CronList` 找到该自动化 id → `CronDelete`。说「监控状态」：`CronList` 汇报。

### 定时任务 prompt（自包含，定时运行不依赖本对话）

> 执行 monitor-spec 刷新，全程不要向用户提问，唯一的写操作是更新一个 issue 正文：
> 1. 读 /Users/zhaochaoyi/.agents/skills/monitor-spec/SKILL.md 并严格按其「刷新流程」「标记约定」「状态→颜色」执行，目标是 GitHub issue zhaochy1990/stride-devops#382 的实现 DAG（gh 命令在 /Users/zhaochaoyi/workspace/stride/stride-devops 下执行；代码仓 /Users/zhaochaoyi/workspace/stride/running）。
> 2. 颜色约定：closed=蓝，open 无阻塞=绿，open 有阻塞=灰；只替换正文里 `<!-- monitor-spec:dag:start -->` 与 `<!-- monitor-spec:dag:end -->` 之间的内容，其余不动。
> 3. 完成后输出一行结论（哪些票变色/无变化 + 刷新时间）。若 gh 认证失败或 GitHub API 不可用，直接结束并在下次重试，不要创建、修改或删除任何自动化任务，也不要做其它写操作。

## 注意

- **定时运行绝不创建/修改/删除自动化**（CronCreate/CronUpdate/CronDelete 只出现在用户当面要求的会话里）。
- DAG 是快照，权威状态永远是 GitHub 原生 blocker 与票面 open/closed；发现两者矛盾以票面为准并在汇报里说明。
- 用户只问进度不开定时：跑一次「刷新流程」并汇报即可，不要顺手建自动化。
