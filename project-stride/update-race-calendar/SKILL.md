---
name: update-race-calendar
description: 更新比赛日历，将races目录下的<比赛名-yyyy-mm-dd>.md文件中的信息更新到我们的比赛日历中。
---

# 更新比赛日志

input: races目录下的<比赛名-yyyy-mm-dd>.md文件内容

首先查询生产环境的MySQL数据库，根据比赛名字找到比赛ID，然后调用API更新比赛日历。

## 查生产 MySQL 找比赛ID

生产库是腾讯云 CynosDB，有公网地址，本地直连。连接信息（host/port/user/password）在 .credentials.local 的「生产环境的MySQL账号」段，查询用只读账号 stride_reader（生产的只读操作不需要授权；写库走 API，不用 stride_rw）：

```bash
MYSQL_PWD='<stride_reader密码>' mysql -h sh-cynosdbmysql-grp-pbo3j68k.sql.tencentcdb.com -P 25272 -u stride_reader --default-character-set=utf8mb4 stride \
  -e "SELECT rc.id, rc.name, rc.race_date, rc.city, COUNT(rci.id) AS items FROM race_calendar rc LEFT JOIN race_calendar_item rci ON rci.race_event_id=rc.id WHERE rc.name LIKE \"%合肥%\" GROUP BY rc.id"
```

- 表：`race_calendar` 是比赛（id、name、race_date），`race_calendar_item` 是项目，外键字段叫 `race_event_id`（指向 race_calendar.id）。`races` 表是用户的比赛记录，与此无关。

## 调用 API 更新

admin 凭证在 .credentials.local 文件中。登录 POST https://admin.stride-running.cn/api/auth/login，body 为 `{"email","password"}`，必须带请求头 `X-Client-Id: app_34d7a7c6b07f418b90734beb`（admin 应用 id，缺了报 application_not_found），取返回的 access_token 作后续 Bearer token。

1. 查询这个比赛的详细信息，GET https://admin.stride-running.cn/api/admin/races/<比赛ID>
2. 解析返回的JSON数据，从中提取 items数组，数组中的每个item都表示这个比赛的一个项目类型（如全程马拉松、半程马拉松），从item中提取项目ID和项目名称
3. 检查item中缺少的内容，调用API PATCH https://admin.stride-running.cn/api/admin/races/<比赛ID>/items/<项目ID>。注意：
   - entry_fee 单位是分（180 元 → 18000）；start_time 格式 "HH:MM"。
   - content 是全量替换：PATCH 前先看 item 已有的 content 字段（如 total_ascent_m），请求体里一并带上，否则会被清掉。
   - content_source 只接受闭集值，调研来的资料填 "WebSearch"。
