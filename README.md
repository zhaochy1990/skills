# skills

个人 agent skills 集中管理仓。分两类：**自己写的**（`own/`）和**别人的直接安装用**（`third-party/`），另有 stride 工作区专用的项目级 skills（`project-stride/`）。

## 目录结构

| 目录 | 数量 | 说明 |
| --- | --- | --- |
| `own/` | 6 | 自写：my-workflow（端到端交付）、my-master（epic 派发器）、my-test-agent（E2E 测试）、post-merge-cleanup（合并收尾）、monitor-spec（地图 DAG 刷新）、wechatide-skill（微信开发者工具） |
| `third-party/langchain/` | 20 | LangChain 官方 skills 生态（langchain/langgraph/deep-agents 系列 + swarm） |
| `third-party/matt-pocock/` | 29 | Matt Pocock 工程方法论 skills（wayfinder、grilling、to-spec/to-tickets、triage、tdd 等） |
| `third-party/open-ecosystem/` | 1 | 开放技能市场（find-skills） |
| `project-stride/` | 8 | stride 工作区项目级：course-challenges、marathon-course、fetch-races、update-race-calendar、update-all-races、validate-race-data、loki-logs、clean-local-git |

## 一键安装

### macOS / Linux

```bash
git clone git@github.com:zhaochy1990/skills.git ~/skills
~/skills/install.sh                          # 安装 own + third-party → ~/.agents/skills/
~/skills/install.sh --stride ~/workspace/stride   # （可选）追加项目级 skills
```

### Windows（PowerShell）

```powershell
git clone git@github.com:zhaochy1990/skills.git $HOME\skills
cd $HOME\skills
.\install.ps1                                # 安装 own + third-party → %USERPROFILE%\.agents\skills\
.\install.ps1 -StrideDir C:\path\to\stride    # （可选）追加项目级 skills
```

若 PowerShell 拦截脚本执行：`Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` 后重试。

## 更新与同步

- **更新到本机**：`git pull` 后重跑安装脚本（脚本先删后拷，覆盖更新，重复执行安全）。
- **改了自写 skill**：在 `~/.agents/skills/` 里改完后把对应目录拷回 `own/`（或直接在本仓改），commit + push。
- **third-party 只是快照**：上游更新不自动跟进，需要时从原仓库重取覆盖本仓对应目录。
- 本仓不含插件类 skills（`github:*`、`pdf:*` 等）——它们由 ZCode 插件体系管理，新机器装好插件自动恢复。
