# 话题发帖时间与上游同步约束

本文件记录首页话题卡发帖时间和 GitHub 自动构建的实现边界。后续使用 AI 同步上游代码时，必须先阅读本文件，避免把修改合并到未生效的渲染路径。

## 当前结论

- 分支：`feature/app-topic-created-at`
- 首页普通话题卡默认使用：`buildTopicItem` → `PaintedTopicCard` → `TopicCardLayout`
- `kUsePaintedTopicCard` 当前为 `true`。
- `lib/widgets/topic/topic_card.dart` 是 Widget fallback 路径，不是首页普通话题卡主路径。
- 置顶话题使用 `CompactTopicCard`，不经过普通自绘布局。

## 生效文件

| 文件 | 作用 | 同步要求 |
| --- | --- | --- |
| `lib/widgets/topic/topic_item_builder.dart` | 决定自绘卡、Widget 卡、置顶卡的路由 | 确认 `kUsePaintedTopicCard` 和分支条件未改变 |
| `lib/widgets/topic/topic_card_layout.dart` | 首页普通话题自绘卡的时间排版入口 | 普通话题必须使用 `formatTopicCreatedAt(topic.createdAt)` |
| `lib/utils/topic_created_at_formatter.dart` | 日期格式规则 | 保持今天、本年、跨年的三段规则 |
| `lib/pages/topic_card_style_settings_page.dart` | 设置页预览数据 | 预览 Topic 必须提供 `createdAt` |
| `test/utils/topic_created_at_formatter_test.dart` | 日期边界测试 | 修改格式时同步更新测试 |
| `.github/workflows/app-topic-created-at.yaml` | Android ARM64 自动构建 | 保持独立文件，不修改上游 `build.yaml` |

## 日期格式规则

- 今天：`12:01`
- 本年非今天：`1月15日12:01`
- 其他年份：`2024年1月15日12:01`
- `DateTime` 为空：显示空字符串

## 禁止事项

1. 不要只修改 `lib/widgets/topic/topic_card.dart`，然后认为首页已生效。
2. 不要把普通话题的 `topic.createdAt` 改回 `topic.lastPostedAt`。
3. 不要在普通话题卡重新使用 `TimeUtils.formatRelativeTime`。
4. 不要删除 formatter 引用，除非同步修改所有自绘渲染路径。
5. 不要为了此功能修改上游 `.github/workflows/build.yaml`，使用独立 workflow。
6. 不要把私信或搜索帖子时间误改成普通话题时间，除非需求明确扩大范围。

## 上游同步流程

### 同步前

```powershell
git status --short --branch
git fetch origin
git log --oneline --decorate -5
```

确认工作区干净，并确认当前分支仍从 `main` 派生。不要覆盖用户已有未提交改动。

### 识别冲突文件

```powershell
git diff main...HEAD -- lib/widgets/topic/topic_item_builder.dart lib/widgets/topic/topic_card_layout.dart lib/pages/topic_card_style_settings_page.dart lib/utils/topic_created_at_formatter.dart .github/workflows/app-topic-created-at.yaml
```

如果上游修改了 `topic_item_builder.dart` 或 `topic_card_layout.dart`，先重新确认首页实际 renderer，再解决冲突；不要按文件名猜测生效路径。

### 合并后的不变量

- 普通首页话题卡仍由 `TopicCardLayout` 生成 `timeStr`。
- `timeStr` 来源仍是 `topic.createdAt`。
- formatter 三种日期输出仍符合本文件规则。
- 设置页预览 Topic 仍有非空 `createdAt`。
- GitHub workflow 仍只构建 Android `android-arm64` 并上传 artifact。

### 合并后检查

```powershell
git grep -n "timeStr:.*topic\.createdAt" -- lib/widgets/topic/topic_card_layout.dart
git grep -n "formatTopicCreatedAt" -- lib/widgets/topic/topic_card_layout.dart lib/utils/topic_created_at_formatter.dart
git grep -n "createdAt:" -- lib/pages/topic_card_style_settings_page.dart
git diff --check
```

如果首页仍显示“刚刚/几分钟前”，优先检查 `kUsePaintedTopicCard` 和 `TopicCardLayout`，不要只检查 `topic_card.dart`。

## GitHub 自动构建

`.github/workflows/app-topic-created-at.yaml` 在推送到 `feature/app-topic-created-at` 或手动触发时运行：

1. checkout 子模块；
2. 安装 Java 17、Flutter 3.44.8、Rust 和 Android NDK 27.3.13750724；
3. 使用 `dart tool/flutterw.dart` 构建 Android release APK；
4. 检查 APK 内存在 `lib/arm64-v8a/libdoh_proxy.so`；
5. 上传 `fluxdo-android-arm64` artifact。

这是 GitHub Actions 自动构建和产物上传，不是本地运行，也不是 Google Play 自动发布。

## 回滚策略

- 只回滚时间功能：恢复 `topic_card_layout.dart` 的普通话题 `timeStr`，并成组处理 formatter、测试和 workflow。
- 不要单独删除 `topic_created_at_formatter.dart`，否则 `TopicCardLayout` 会编译失败。
- 如果上游重构自绘卡，先暂停合并，重新确认新的时间排版入口，再迁移 formatter 调用。
