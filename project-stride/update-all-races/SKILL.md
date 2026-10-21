---
name: update-all-races
description: 批量回填比赛日历：遍历races目录下所有<比赛名-yyyy-mm-dd>.md文件，逐场按update-race-calendar流程写入生产，用progress.json记录进度，断点续跑、失败不中断。
---

# 批量回填所有比赛

对 races 目录下每一个 <比赛名-yyyy-mm-dd>.md，执行 update-race-calendar 技能的单场流程，把调研结果写入生产比赛日历。progress.json 是唯一的进度账本：重跑时只处理未完成的和失败的。

## progress.json

路径 races/progress.json，不存在则创建。结构：

```json
{
  "races": {
    "<文件名>.md": {
      "status": "done",
      "race_id": 30,
      "updated_at": "2026-09-28T15:00:00+08:00"
    },
    "<文件名>.md": {
      "status": "failed",
      "race_id": null,
      "error": "race_calendar 中未找到该日期的匹配比赛",
      "updated_at": "..."
    }
  }
}
```

- 待处理 = 不在 progress.json 里的文件，或 status=failed 的（失败的要重试）。
- status=done 的跳过，不重复 PATCH。
- 每完成一场或确定失败一场，立即写回 progress.json——不要全部跑完才写，随时中断都能续跑。

## 批处理流程

1. 列出 races/ 下所有匹配 `*-????-??-??.md` 的文件（race.md 是赛事清单、progress.json 是进度账本，都不是比赛文件），按文件名里的日期排序。
2. 管理后台登录一次拿 token，整批复用；token 有效期 1 小时，遇到 401 就重新登录再试一次。
3. 逐场执行 update-race-calendar 技能的流程：查库找比赛ID → GET 详情 → PATCH 缺失字段。entry_fee 单位、content 全量替换等约束以该技能为准。
4. 每场结束立即更新 progress.json。

### 文件名 → 数据库比赛的匹配

文件名与 race_calendar.name 通常不一致（安徽合肥马拉松-2026-11-08.md ↔ 2026合肥马拉松）。匹配方法：

- 用文件名里的日期查 race_calendar.race_date。
- 再用文件名去掉省份前缀（安徽/山东/河南/湖北/…）和"马拉松"字样的核心地名做 LIKE（如 `%合肥%`）。
- 命中多条或零条时，用 md 文件首行的比赛全称、主办城市与候选行的 city/province 对照判断；仍无法唯一确定 → status=failed，error 里写明候选清单。
- 批量跑可以先用一条 SQL 把涉及日期的比赛全部查出来建映射，再逐场对号。

### 失败处理

单场失败（匹配不到比赛、API 反复报错、md 内容不足以构造 PATCH）记 failed 并继续下一场，不中断整个批。

## 完成标准

races/ 下所有 `*-????-??-??.md` 文件在 progress.json 里均为 done 或 failed；最后报告成功场数、失败场数和每场的失败原因。
