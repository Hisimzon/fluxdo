# 话题 AI 摘要强制刷新设计

## 目标

普通展开摘要继续允许服务端返回缓存；只有用户主动点击刷新时传递
`skipAgeCheck=true`，强制重新生成，并让 loading、MessageBus streaming 和最终摘要
继续通过同一个 Riverpod 状态展示。

## 方案

- 使用 `TopicSummaryRequest` 作为 `topicSummaryProvider` 的 family key。
- 请求包含 `topicId`、`skipAgeCheck` 和 `generation`。
- 首次展开使用默认请求：`skipAgeCheck=false`。
- 每次点击刷新调用 `nextRegeneration()`：设置 `skipAgeCheck=true` 并递增
  `generation`，保证 Riverpod 创建新的流请求。
- 折叠容器和摘要正文监听同一个请求 key，避免重复请求和状态不一致。
- Service 层保持不变，继续负责 POST/GET 兼容和 MessageBus 增量结果。

## 不变量

- 页面首次打开、折叠和重新展开不会强制消耗 AI。
- 只有明确点击刷新才绕过摘要年龄检查。
- 连续多次刷新都能产生新的请求。
- 新流产生的数据直接替换旧 Provider 数据，完成后保留最新摘要。
