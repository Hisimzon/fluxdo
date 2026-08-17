# 话题 AI 摘要强制刷新实现计划

> **面向 AI 代理的工作者：** 按复选框顺序实现并验证；保持最小改动，不运行或部署 App。

**目标：** 用户主动刷新时强制重新生成摘要，并显示 loading/streaming/最终结果。

**架构：** 以包含刷新 generation 的请求对象作为 Riverpod family key。折叠头部和摘要正文共享该 key，Service 层继续输出 MessageBus 流。

**技术栈：** Flutter、Dart、Riverpod、Dio、Discourse MessageBus。

---

### 任务 1：请求身份与 Provider

**文件：**
- 创建：`lib/providers/topic_summary_request.dart`
- 修改：`lib/providers/topic_detail_provider.dart`
- 测试：`test/providers/topic_summary_request_test.dart`

- [x] 定义默认缓存请求和递增 generation 的强制刷新请求。
- [x] Provider 将 `skipAgeCheck` 原样传给 `watchTopicSummary`。
- [x] 测试默认请求、强制刷新和连续刷新使用不同 key。

### 任务 2：组件状态流

**文件：**
- 修改：`lib/widgets/topic/topic_summary_widget.dart`

- [x] 折叠容器保存当前 `TopicSummaryRequest`。
- [x] 用户点击刷新时切换为下一次强制刷新请求。
- [x] 头部和正文共享请求，显示 loading、streaming 和最终摘要。

### 任务 3：验证与交付

- [x] 运行 `git diff --check`。
- [x] 检查仅目标文件发生变化。
- [x] 提交并推送 `feature/app-topic-created-at`。
