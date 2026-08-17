# 话题 AI 摘要与上游同步冲突约束

本文件记录话题详情页 AI 摘要的本地行为和上游合并边界。后续使用 AI 同步上游代码时，必须保留上游原有摘要能力，同时保留本分支的缓存读取、主动强制刷新、流式展示和终态收敛功能。

## 当前功能不变量

- 普通首次展开摘要使用 `skipAgeCheck=false`，允许服务端返回缓存摘要。
- 只有用户主动点击“刷新”时使用 `skipAgeCheck=true`，强制重新生成。
- 生成期间必须展示 loading 或 streaming 状态。
- MessageBus 的增量摘要持续替换当前摘要内容。
- 最终 `done=true` 后必须产生 `isStreaming=false` 的终态摘要。
- 如果最终结束帧没有 `ai_topic_summary`，必须使用最近一帧摘要补发终态，不能让旧的 streaming 状态永久保留。
- 连续多次刷新必须生成不同的 Provider key。

## 生效文件

| 文件 | 作用 | 同步要求 |
| --- | --- | --- |
| `lib/providers/topic_summary_request.dart` | 区分普通读取和用户强制刷新请求 | 保留 `skipAgeCheck`、`generation` 和对象相等性 |
| `lib/providers/topic_detail_provider.dart` | 将请求参数传给摘要 Service | 不要恢复为只接收 `int topicId` |
| `lib/widgets/topic/topic_summary_widget.dart` | 展开、刷新、loading、streaming 和终态展示 | 头部与正文必须监听同一个请求 key |
| `lib/services/discourse/_topics.dart` | 请求摘要、订阅 MessageBus、收敛结束状态 | 保留 POST/GET 兼容、`skip_age_check` 和最终终态补发 |
| `lib/models/topic.dart` | 解析 `TopicSummary` 状态 | `done=true` 时 `isStreaming` 必须为 `false` |
| `test/providers/topic_summary_request_test.dart` | 验证刷新请求身份 | 同步请求模型时更新连续刷新断言 |

## 禁止的冲突解决方式

1. 不要直接选择 `theirs` 覆盖本地摘要逻辑。
2. 不要直接选择 `ours` 丢弃上游的 API 兼容、权限或错误处理。
3. 不要把 `skipAgeCheck=true` 放到首次展开路径，否则每次打开详情都会触发 AI 生成。
4. 不要只修改刷新按钮而不修改 Provider 请求 key，否则仍可能复用旧流状态。
5. 不要只处理带摘要内容的结束帧；结束帧没有摘要内容时也必须补发终态。
6. 不要用 `update['done'] == true` 作为唯一判断，需兼容上游返回字符串或数字布尔值。
7. 不要把首页话题卡时间格式的修改合并到摘要文件，两个功能保持独立。

## 上游同步流程

### 同步前

```powershell
git status --short --branch
git fetch origin
git log --oneline --decorate -5
```

确认当前分支为 `feature/app-topic-created-at`，工作区干净。不要覆盖已有未提交修改。

### 识别冲突

```powershell
git diff main...HEAD -- lib/providers/topic_summary_request.dart lib/providers/topic_detail_provider.dart lib/widgets/topic/topic_summary_widget.dart lib/services/discourse/_topics.dart lib/models/topic.dart
git diff --name-only main...HEAD
```

如果上游重构了摘要 Provider、详情摘要组件或 MessageBus 接口，先重新画出“展开 → 请求 → 流式更新 → done 终态”的调用链，再手工合并。不要按冲突块上下文直接接受一侧内容。

### 手工合并原则

1. 先保留上游新增的接口、鉴权、错误处理和 POST/GET 兼容逻辑。
2. 再把 `TopicSummaryRequest` 的 `skipAgeCheck` 和 `generation` 接回新的 Provider 参数。
3. 确认首次展开传 `false`，刷新动作传 `true`。
4. 确认头部 loading 状态和正文 Provider 使用同一个请求 key。
5. 确认每个带摘要的中间帧都更新缓存摘要。
6. 确认 `done=true` 帧即使没有摘要内容，也会把最近摘要标记为 `done=true` 后发出。
7. 确认 `done` 判断兼容 `true`、`"true"` 和 `1`。

## 合并后检查

```powershell
git grep -n "skipAgeCheck" -- lib/providers/topic_summary_request.dart lib/providers/topic_detail_provider.dart lib/widgets/topic/topic_summary_widget.dart
git grep -n "nextRegeneration" -- lib/providers/topic_summary_request.dart lib/widgets/topic/topic_summary_widget.dart
git grep -n "_isTopicSummaryDone\|latestSummaryJson\|summaryJson\['done'\]" -- lib/services/discourse/_topics.dart
git grep -n "topicSummaryProvider(_summaryRequest)" -- lib/widgets/topic/topic_summary_widget.dart
git diff --check
```

验证标准：首次展开不强制刷新，主动刷新确实携带 `skipAgeCheck=true`，流式结束后 spinner 消失，且最终摘要内容保留最新版本。

## 回滚策略

- 如果只回滚强制刷新：恢复 `TopicSummaryRequest` 和 Provider 参数，但不要回滚上游 Service 的 API 兼容代码。
- 如果只回滚终态修复：保留 `skipAgeCheck` 功能；回滚前必须确认不会再次出现“摘要已完成但仍显示 loading”。
- 如果上游重构了摘要流：暂停合并，先补充新的结束帧 fixture 或测试，再迁移本地终态收敛逻辑。
