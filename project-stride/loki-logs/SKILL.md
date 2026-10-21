---
name: loki-logs
description: 查询 stride 生产环境的 Loki 日志（k3s 集群 ns=infra，保留 14 天），用于排障/debug。用户说"查日志""看看 XX 的日志""为什么挂了""什么时候开始报错""翻翻 crash 前的输出"等场景时使用。覆盖集群 pod 日志（namespace/pod/container 标签）与 auth 边缘 caddy 访问日志（service 标签）。只读查询，不改任何配置。
---

# 查询 stride 生产 Loki 日志

唯一可信的日志存量：**k8s pod 日志 + auth 边缘 caddy 访问日志**全量进 Loki（14 天保留，之后 compactor 自动删）。Pod 被删后 `kubectl logs` 就没了，但 **Loki 里还在**——这是查"已死容器"临终日志的唯一途径。

- Loki：ns=infra 的 `deploy/loki`（3.7.7），无认证
- Grafana UI（人类用）：https://monitoring.stride-running.cn → Explore（数据源已自动配置）
- 本 skill 走 kubectl port-forward + HTTP API，无需登录

## 第 0 步：前置检查（30 秒，省十分钟）

```bash
# 1) kubectl 能用吗？（卡住/连接拒绝 = 本地隧道断了）
kubectl get nodes >/dev/null 2>&1 || zsh -ic 'k3s-tunnel'

# 2) 起/重起 Loki 的 port-forward（已在本机 3100 监听则跳过）
pkill -f "port-forward deploy/loki" 2>/dev/null
(kubectl -n infra port-forward deploy/loki 3100:3100 >/dev/null 2>&1 &)
sleep 3
curl -s http://localhost:3100/ready   # => "ready"
```

## 查询接口与解析模板

统一用 `/loki/api/v1/query_range`（GET + URL encode），常用参数：
`query`（LogQL）、`since`（如 `1h`/`24h`）、`limit`、`direction=backward`（**新日志在前，务必带上**，否则默认从头返回最老的）。

标准解析模板（日志查询，`stream` 键）：

```bash
curl -s --get "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={container="stride-api"}' \
  --data-urlencode "since=1h" --data-urlencode "limit=20" \
  --data-urlencode "direction=backward" | python3 -c "
import json,sys,datetime
r=json.load(sys.stdin)['data']['result']
for s in r:
    for v in s['values']:
        ts=datetime.datetime.fromtimestamp(int(v[0])/1e9).strftime('%m-%d %H:%M:%S')
        print(ts, v[1][:200])
"
```

## 场景配方（把 container/pod 换成目标）

| 场景 | LogQL |
|---|---|
| 看某服务日志 | `{container="stride-worker"}` |
| 只看错误 | `{namespace="stride"} \|~ "(?i)error\|fatal\|panic"` |
| 已删 pod 的临终日志（取证） | `{pod=~"stride-worker-5dbc6dbc4.*"}` （按旧 pod 名前缀） |
| 关键字/ID 全文搜 | `{namespace="stride"} \|~ "某userId\|某orderId"` |
| caddy 访问日志（auth 边缘） | `{service="caddy"}` |
| caddy 非 2xx 请求 | `{service="caddy"} \|~ '"status":5\d\d\|"status":4\d\d'` |
| 只看 stderr（错误输出通道） | `{namespace="stride", stream="stderr"}` |
| 重启前的最后输出 | 查询目标 pod + `direction=backward`，时间窗卡在重启时刻之前（事件里看时间） |
| 日志量热度（谁在刷） | `sum by (container) (count_over_time({namespace=~"stride\|infra"}[5m]))` |
| 某时间段（不是相对 since） | 加 `--data-urlencode "from=<ns毫秒>" --data-urlencode "to=<ns毫秒>"` |

标签体系：集群 pod 一律有 `namespace` / `pod` / `container` / `filename`；caddy（docker 侧 alloy 采集）用 `service="caddy"`。可用标签先查 `/loki/api/v1/labels`。

## 踩过的坑（都真踩过）

1. **metric 类查询（count_over_time 等）的解析键是 `metric` 不是 `stream`**——报 KeyError 就换键。
2. **2026-10-09 11:00 前的历史日志带 CRI 前缀**（`时间戳 stdout F 正文`，当时采集端没剥）——查旧日志裸看行即可；对旧日志用 `| json` 会**静默丢弃每一行**，别用。此后新日志已由 alloy `stage.cri` 剥壳并加 `stream` 标签，`| json` 正常可用：`{container="stride-api"} | json | line_format "{{.T}} {{.Msg}}"`。Go 服务字段是 `L/T/Msg/error/S`，TS 服务是 pino `level/time/name/msg`——字段名写错输出空串，先裸看一行再拼模板。
3. **`direction` 不带默认返回最老的**，debug 时永远要 `direction=backward`。
4. port-forward 会随 pod 重建/长时间闲置断掉，`connection refused` 就按第 0 步重开。
5. **kubectl 隧道（16443）和 Loki port-forward（3100）是两条独立通道**，挂的症状都是 curl 卡住——先 `kubectl get nodes` 分辨是哪条断了。
6. Grafana 若查询报 `Plugin not registered`，是 k3s 已修过的老问题（GF_PLUGINS_PREINSTALL_DISABLED），直接用本 skill 的 API 路径绕过 UI。

## 边界

- 只读。改 alloy 采集配置、Loki 保留策略等运维动作不属本 skill（见 stride-devops/k8s/README.md）。
- 日志只到 14 天；更早的已按设计删除，别承诺能查到。
