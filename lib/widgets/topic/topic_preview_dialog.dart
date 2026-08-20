import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:share_plus/share_plus.dart';
import '../../models/topic.dart';
import '../../models/category.dart';
import '../../providers/discourse_providers.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/selected_topic_provider.dart';
import '../../utils/font_awesome_helper.dart';
import '../../utils/share_utils.dart';
import '../../utils/url_helper.dart';
import '../../services/discourse_cache_manager.dart';
import '../../pages/topic_detail_page/topic_detail_page.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../common/relative_time_text.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/number_utils.dart';
import '../common/emoji_text.dart';
import '../common/smart_avatar.dart';
import '../common/topic_badges.dart';
import '../../utils/fluxdo_render_callbacks.dart';
import '../../pages/category_topics_page.dart';
import '../../pages/tag_topics_page.dart';
import '../../../../../l10n/s.dart';

/// 预览弹窗中的操作项
class PreviewAction {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;

  const PreviewAction({
    required this.icon,
    required this.label,
    this.color,
    required this.onTap,
  });
}

/// 取卡片(或任意锚点 widget)的屏幕 rect 作为一镜到底动画起点。
/// [cardContext] 必须是卡片自身的 context(Builder 紧贴卡片构造);
/// 卡片外壳含底部间距(Padding),[bottomGap] 裁掉后才是视觉卡身:
/// 普通/自绘卡 8、置顶紧凑卡 6。卡片未挂载/未布局时返回 null。
Rect? topicCardAnchorRect(BuildContext cardContext, {double bottomGap = 8}) {
  final box = cardContext.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  final origin = box.localToGlobal(Offset.zero);
  return Rect.fromLTRB(
    origin.dx,
    origin.dy,
    origin.dx + box.size.width,
    origin.dy + box.size.height - bottomGap,
  );
}

/// 话题预览弹窗 - 长按卡片时显示
class TopicPreviewDialog extends ConsumerStatefulWidget {
  final Topic topic;
  final VoidCallback? onOpen;
  final List<PreviewAction>? actions;
  final WidgetBuilder? customActionPanelBuilder;
  final Future<String?> Function()? firstPostLoader;

  /// 锚点上下文所在的平行视界栈(show 时捕获)。弹窗自身是独立路由,
  /// 体内 context 找不到 EmbeddedStackScope;预览内容里的内链点击要
  /// 压回锚点的栈(与正文内链同语义),没有则全屏 push。
  final SelectedTopicProvider? paneStack;

  /// 一镜到底模式:非空时弹窗壳从 [anchorRect](长按卡片的屏幕 rect)
  /// 连续变形到居中弹窗 —— 内容自始至终嵌在壳内随其变形(裁剪窗从
  /// 卡片大小展开),没有"空壳飞行"段;关闭沿同路径收回。由路由
  /// animation 驱动([show] 的 anchorRect 路径传入)。
  final Animation<double>? morphAnimation;

  /// 一镜到底起点:卡片的屏幕 rect(已裁掉卡片底部间距)
  final Rect? anchorRect;

  /// 一镜到底起点底色:卡片外壳底色(surfaceContainerLow 系),
  /// 与弹窗壳 surface 做插值,起步无缝
  final Color? anchorColor;

  /// 一镜到底起点圆角(卡片 10 → 弹窗 20)
  final double anchorRadius;

  const TopicPreviewDialog({
    super.key,
    required this.topic,
    this.onOpen,
    this.actions,
    this.customActionPanelBuilder,
    this.firstPostLoader,
    this.paneStack,
    this.morphAnimation,
    this.anchorRect,
    this.anchorColor,
    this.anchorRadius = 10,
  });

  @override
  ConsumerState<TopicPreviewDialog> createState() => _TopicPreviewDialogState();

  /// 显示预览弹窗
  ///
  /// [anchorRect] 为长按卡片的全局 rect(已裁掉卡片底部间距)。
  /// 传入时走一镜到底:弹窗壳从卡片位置/底色/圆角连续变形到居中
  /// 弹窗,关闭沿同路径收回;未传入回退为中心缩放(防御兜底)。
  static Future<void> show(
    BuildContext context, {
    required Topic topic,
    VoidCallback? onOpen,
    List<PreviewAction>? actions,
    WidgetBuilder? customActionPanelBuilder,
    Future<String?> Function()? firstPostLoader,
    Rect? anchorRect,
    Color? anchorColor,
    double anchorRadius = 10,
  }) {
    // 触觉反馈
    HapticFeedback.mediumImpact();

    // pop 弹窗后锚点 context 可能已失效,进弹窗前先捕获平行视界栈。
    final paneStack = EmbeddedStackScope.maybeOf(context);

    if (anchorRect != null) {
      // 一镜到底:变形由弹窗内部根据路由 animation 自驱(内容嵌在壳内
      // 随壳变形),这里 transitionBuilder 必须恒等 —— 默认的整页淡入
      // 会让壳从透明浮现,破坏"卡片浮起"的连续性
      return showAppGeneralDialog(
        context: context,
        barrierDismissible: true,
        barrierLabel: S.current.common_closePreview,
        barrierColor: Colors.black54,
        transitionDuration: const Duration(milliseconds: 350),
        transitionBuilder: (context, animation, secondaryAnimation, child) =>
            child,
        pageBuilder: (context, animation, secondaryAnimation) {
          return TopicPreviewDialog(
            topic: topic,
            onOpen: onOpen,
            actions: actions,
            customActionPanelBuilder: customActionPanelBuilder,
            firstPostLoader: firstPostLoader,
            paneStack: paneStack,
            morphAnimation: animation,
            anchorRect: anchorRect,
            anchorColor: anchorColor,
            anchorRadius: anchorRadius,
          );
        },
      );
    }

    return showAppGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: S.current.common_closePreview,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) {
        return TopicPreviewDialog(
          topic: topic,
          onOpen: onOpen,
          actions: actions,
          customActionPanelBuilder: customActionPanelBuilder,
          firstPostLoader: firstPostLoader,
          paneStack: paneStack,
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curvedAnimation = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutBack,
        );
        return ScaleTransition(
          scale: curvedAnimation,
          child: FadeTransition(opacity: animation, child: child),
        );
      },
    );
  }
}

class _TopicPreviewDialogState extends ConsumerState<TopicPreviewDialog> {
  String? _firstPostCooked;
  bool _isLoading = true;
  bool _loadFailed = false;

  // ── 一镜到底(morphAnimation 非空) ──
  /// 内容柱(壳体 + 底部操作面板)的测量锚。注意框架禁止在 build 阶段
  /// 读 Element.size,尺寸统一经 [_scheduleSizeSync] 在 postFrame /
  /// 尺寸变化通知里写入 [_contentSize];写入前壳钳在锚点作蓄力起步
  final GlobalKey _contentKey = GlobalKey();
  Size? _contentSize;

  /// 弹簧曲线缓存:curveFor 的解析解含二分/log 预热,不能逐帧重建
  Curve? _spatialCurve;
  Curve? _effectsCurve;
  bool? _cachedM3e;
  Topic get topic => widget.topic;

  @override
  void initState() {
    super.initState();
    _loadFirstPost();
    // 一镜到底:首帧布局后尽快测得内容柱尺寸,让动画尽早起步
    // (路由插入帧 page 可能 offstage 不参与布局,故逐帧重试)
    if (widget.morphAnimation != null) _scheduleSizeSync();
  }

  Future<void> _loadFirstPost() async {
    try {
      final cooked = widget.firstPostLoader != null
          ? await widget.firstPostLoader!()
          : await ref
                .read(discourseServiceProvider)
                .getTopicFirstPostCooked(topic.id);
      if (!mounted) return;
      setState(() {
        _firstPostCooked = cooked;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadFailed = true;
      });
    }
  }

  void _ensureMorphCurves(bool m3e) {
    if (_cachedM3e == m3e && _spatialCurve != null) return;
    _cachedM3e = m3e;
    // 空间属性(位置/尺寸/圆角):欠阻尼弹簧,带轻微过冲的落座感;
    // 效果属性(颜色/阴影/透明度):临界阻尼,不过冲
    const duration = Duration(milliseconds: 350);
    _spatialCurve = m3e
        ? M3eMotion.defaultSpatial.curveFor(duration)
        : Curves.easeInOutCubic;
    _effectsCurve = m3e
        ? M3eMotion.defaultEffects.curveFor(duration)
        : Curves.easeInOut;
  }

  /// 内容尺寸变化(正文加载完成等)时安排重测,壳 rect 下一帧跟上
  bool _onContentSizeChanged(SizeChangedLayoutNotification notification) {
    _scheduleSizeSync();
    return true;
  }

  /// postFrame 里读 [_contentKey] 的布局尺寸写入 [_contentSize];
  /// 未布局(首帧 offstage 等)则逐帧重试直到测得。壳 rect 的动画
  /// 终点与收回起点都取自这里 —— 内容长高后壳自动跟随
  void _scheduleSizeSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final render = _contentKey.currentContext?.findRenderObject();
      if (render is RenderBox && render.hasSize) {
        if (render.size != _contentSize) {
          setState(() => _contentSize = render.size);
        }
      } else {
        _scheduleSizeSync();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenSize = MediaQuery.of(context).size;
    final maxWidth = screenSize.width * 0.9;
    final maxHeight = screenSize.height * 0.7;

    // 获取分类信息
    final categoryMap = ref.watch(categoryMapProvider).value;
    final categoryId = int.tryParse(topic.categoryId);
    final category = categoryMap?[categoryId];

    // 图标逻辑
    FaIconData? faIcon = FontAwesomeHelper.getIcon(category?.icon);
    String? logoUrl = category?.uploadedLogo;

    if (faIcon == null &&
        (logoUrl == null || logoUrl.isEmpty) &&
        category?.parentCategoryId != null) {
      final parent = categoryMap?[category!.parentCategoryId];
      faIcon = FontAwesomeHelper.getIcon(parent?.icon);
      logoUrl = parent?.uploadedLogo;
    }

    final hasActions = widget.actions != null && widget.actions!.isNotEmpty;
    final hasCustomActionPanel = widget.customActionPanelBuilder != null;

    final morphing = widget.morphAnimation != null;

    // 壳体内容(两种模式共用):渐变条 + 自定义面板 + 滚动内容 + 底栏
    final sheetBody = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 4,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                theme.colorScheme.primaryContainer,
                theme.colorScheme.tertiaryContainer,
              ],
            ),
          ),
        ),
        if (hasCustomActionPanel)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: widget.customActionPanelBuilder!(context),
          ),
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              hasCustomActionPanel ? 16 : 20,
              20,
              20,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTitle(context, theme),
                const SizedBox(height: 12),
                _buildAuthorInfo(context, theme),
                if (category != null || topic.tags.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _buildCategoryAndTags(
                    context,
                    theme,
                    category,
                    faIcon,
                    logoUrl,
                  ),
                ],
                const SizedBox(height: 16),
                _buildPostContent(context, theme),
                const SizedBox(height: 16),
                if (topic.posters.length > 1)
                  _buildParticipants(context, theme),
                _buildStats(context, theme),
              ],
            ),
          ),
        ),
        _buildActions(context, theme),
      ],
    );

    final contentColumn = Column(
      key: const ValueKey('topic-preview-root'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          // 一镜到底模式的底色/圆角/阴影/裁剪全由飞行壳提供,这里只留
          // transparency Material 作 InkWell 载体,避免双层壳叠加
          child: morphing
              ? Material(type: MaterialType.transparency, child: sheetBody)
              : Material(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  elevation: 8,
                  child: sheetBody,
                ),
        ),
        if (hasActions) ...[
          const SizedBox(height: 8),
          _buildCustomActions(context, theme),
        ],
      ],
    );

    if (morphing) return _buildMorphingShell(context, contentColumn);

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth.clamp(300, 500),
          maxHeight: maxHeight,
        ),
        child: contentColumn,
      ),
    );
  }

  /// 一镜到底壳层:飞行壳(Material)从锚点 rect 连续变形到内容最终
  /// rect;内容自始至终嵌在壳内(OverflowBox 按目标宽布局、顶部对齐),
  /// 裁剪窗随壳从卡片大小展开 —— 内容全程随壳飞行,没有"空壳移动"段。
  /// 内容尺寸由 SizeChangedLayoutNotifier 实时上报:正文加载完成壳
  /// 自动跟随长高;反向收回时从内容当前实际尺寸飞回锚点。
  Widget _buildMorphingShell(BuildContext context, Widget body) {
    final theme = Theme.of(context);
    final screen = MediaQuery.sizeOf(context);
    final dialogWidth = (screen.width * 0.9).clamp(300.0, 500.0);
    final animation = widget.morphAnimation!;
    final anchor = widget.anchorRect!;
    final anchorColor =
        widget.anchorColor ??
        theme.cardTheme.color ??
        theme.colorScheme.surfaceContainerLow;
    _ensureMorphCurves(M3eFlags.of(context).enabled);

    return AnimatedBuilder(
      animation: animation,
      builder: (context, contentBody) {
        final rawT = animation.value;
        // 内容尺寸经 postFrame 测得前(至多前两帧)壳钳在锚点,作蓄力起步
        final size = _contentSize;
        final spatialT = size == null ? 0.0 : _spatialCurve!.transform(rawT);
        final effectsT = _effectsCurve!.transform(rawT);
        final dest = size == null
            ? anchor
            : Rect.fromLTWH(
                (screen.width - size.width) / 2,
                (screen.height - size.height) / 2,
                size.width,
                size.height,
              );
        final shellRect = Rect.lerp(anchor, dest, spatialT)!;
        // 起步快速淡入:柔化"卡片小标题 → 弹窗大标题"的换皮;
        // 收回沿同一曲线,末段内容渐隐、壳缩回卡片后无缝交还
        final contentOpacity = const Interval(
          0.0,
          0.22,
          curve: Curves.easeOut,
        ).transform(rawT);

        return Stack(
          children: [
            Positioned.fromRect(
              key: const ValueKey('morphing-shell'),
              rect: shellRect,
              child: Material(
                elevation: 8 * effectsT,
                borderRadius: BorderRadius.circular(10 + (20 - 10) * spatialT),
                clipBehavior: Clip.antiAlias,
                color: Color.lerp(
                  anchorColor,
                  theme.colorScheme.surface,
                  effectsT,
                ),
                child: OverflowBox(
                  alignment: Alignment.topCenter,
                  minWidth: dialogWidth,
                  maxWidth: dialogWidth,
                  // 必须显式给 0:null 会继承父级 tight 约束(壳高),
                  // 内容被强制撑到壳高 → 测得的"内容高"失真自锁,
                  // 落座后壳比内容高出一截(底部空白)
                  minHeight: 0,
                  maxHeight: screen.height,
                  child: Opacity(
                    opacity: contentOpacity,
                    child: IgnorePointer(
                      // 飞行期间不响应指针,落座后才开放交互
                      ignoring: rawT < 1.0,
                      child: contentBody!,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
      // 尺寸监听挂在 AnimatedBuilder 的常量 child 上,只建一次,
      // 不随动画逐帧重建
      child: NotificationListener<SizeChangedLayoutNotification>(
        onNotification: _onContentSizeChanged,
        child: SizeChangedLayoutNotifier(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: screen.height * 0.7),
            child: KeyedSubtree(key: _contentKey, child: body),
          ),
        ),
      ),
    );
  }

  Widget _buildPostContent(BuildContext context, ThemeData theme) {
    if (_isLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: LoadingSpinner(size: 24),
        ),
      );
    }

    if (_firstPostCooked != null &&
        _firstPostCooked!.isNotEmpty &&
        !_loadFailed) {
      // 加载成功：渲染主贴 HTML
      final contentFontScale = ref.watch(preferencesProvider).contentFontScale;
      return FluxdoRenderCallbacks.generic(
        heroTagNamespace: 'topic_preview_${topic.id}',
        topicId: topic.id,
        onInternalLinkTap: (topicId, topicSlug, postNumber) {
          // 锚点在平行视界面板里=压回其栈(show 时捕获,pop 后锚点
          // context 已不可用);否则全屏 push。container/navigator 都要
          // 在 pop 前取——pop 后本 context deactivate,祖先查找会抛。
          final stack = widget.paneStack;
          final container = stack != null
              ? ProviderScope.containerOf(context, listen: false)
              : null;
          final navigator = Navigator.of(context);
          navigator.pop();
          if (stack != null) {
            container!
                .read(stack.notifier)
                .push(
                  topicId: topicId,
                  initialTitle: topicSlug,
                  scrollToPostNumber: postNumber,
                );
            return;
          }
          navigator.push(
            MaterialPageRoute(
              builder: (_) => TopicDetailPage(
                topicId: topicId,
                initialTitle: topicSlug,
                scrollToPostNumber: postNumber,
              ),
            ),
          );
        },
      ).render(
        cookedHtml: _firstPostCooked!,
        baseTextStyle: theme.textTheme.bodyMedium?.copyWith(
          height: 1.5,
          fontSize:
              (theme.textTheme.bodyMedium?.fontSize ?? 14) * contentFontScale,
        ),
        compact: true,
        selectionEnabled: false,
      );
    }

    // 加载失败：降级展示 excerpt
    if (topic.excerpt != null && topic.excerpt!.isNotEmpty) {
      return _buildExcerptFallback(theme);
    }

    return const SizedBox.shrink();
  }

  Widget _buildExcerptFallback(ThemeData theme) {
    final cleanExcerpt = topic.excerpt!
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&hellip;', '...')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .trim();

    if (cleanExcerpt.isEmpty) return const SizedBox.shrink();

    final contentFontScale = ref.watch(preferencesProvider).contentFontScale;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        cleanExcerpt,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          height: 1.6,
          fontSize:
              (theme.textTheme.bodyMedium?.fontSize ?? 14) * contentFontScale,
        ),
        maxLines: 8,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildTitle(BuildContext context, ThemeData theme) {
    return Text.rich(
      TextSpan(
        style: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
        children: [
          if (topic.closed)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  Symbols.lock_rounded,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (topic.pinned)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  Symbols.push_pin_rounded,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          if (topic.hasAcceptedAnswer)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  Symbols.check_box_rounded,
                  size: 20,
                  color: Colors.green,
                ),
              ),
            ),
          ...EmojiText.buildEmojiSpans(
            context,
            topic.title,
            theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAuthorInfo(BuildContext context, ThemeData theme) {
    String? avatarUrl;
    String username;

    if (topic.posters.isNotEmpty && topic.posters.first.user != null) {
      final op = topic.posters.first.user!;
      avatarUrl = op.getAvatarUrl(size: 56);
      username = op.username;
    } else {
      username = topic.lastPosterUsername ?? '';
    }

    return Row(
      children: [
        SmartAvatar(imageUrl: avatarUrl, radius: 14, fallbackText: username),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            username,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurface,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (topic.createdAt != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              '·',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          RelativeTimeText(
            dateTime: topic.createdAt,
            displayStyle: TimeDisplayStyle.prefixed,
            prefix: S.current.topic_createdAt,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCategoryAndTags(
    BuildContext context,
    ThemeData theme,
    Category? category,
    FaIconData? faIcon,
    String? logoUrl,
  ) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        // 分类
        if (category != null)
          GestureDetector(
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => CategoryTopicsPage(category: category),
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _parseColor(category.color).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _parseColor(category.color).withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (faIcon != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FaIcon(
                        faIcon,
                        size: 12,
                        color: _parseColor(category.color),
                      ),
                    )
                  else if (logoUrl != null && logoUrl.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Image(
                        image: discourseImageProvider(
                          UrlHelper.resolveUrlWithCdn(logoUrl),
                        ),
                        width: 12,
                        height: 12,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) {
                          return _buildCategoryDot(category);
                        },
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _buildCategoryDot(category),
                    ),
                  Text(
                    category.name,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),

        // 标签
        ...topic.tags.map(
          (tag) => TagBadge(
            name: tag.name,
            size: const BadgeSize(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              radius: 8,
              iconSize: 12,
              fontSize: 13,
            ),
            textStyle: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TagTopicsPage(tagName: tag.name),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildParticipants(BuildContext context, ThemeData theme) {
    final participants = topic.posters.take(5).toList();

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Text(
            S.current.topic_participants,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 28,
              child: Stack(
                children: List.generate(participants.length, (index) {
                  final poster = participants[index];
                  String? avatarUrl;
                  String fallback = '';

                  if (poster.user != null) {
                    avatarUrl = poster.user!.getAvatarUrl(size: 56);
                    fallback = poster.user!.username;
                  }

                  return Positioned(
                    left: index * 20.0,
                    child: SmartAvatar(
                      imageUrl: avatarUrl,
                      radius: 14,
                      fallbackText: fallback,
                      border: Border.all(
                        color: theme.colorScheme.surface,
                        width: 2,
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStats(BuildContext context, ThemeData theme) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildStatItem(
                context,
                Symbols.chat_bubble_rounded,
                S.current.topic_replyCount(
                  (topic.postsCount - 1).clamp(0, 999999),
                ),
              ),
            ),
            Expanded(
              child: _buildStatItem(
                context,
                Symbols.favorite_border_rounded,
                S.current.topic_likeCount(
                  NumberUtils.formatCount(topic.likeCount),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _buildStatItem(
                context,
                Symbols.visibility_rounded,
                S.current.topic_viewCount(NumberUtils.formatCount(topic.views)),
              ),
            ),
            Expanded(
              child: _buildStatWidgetItem(
                context,
                Symbols.access_time_rounded,
                RelativeTimeText(
                  dateTime: topic.lastPostedAt,
                  displayStyle: TimeDisplayStyle.prefixed,
                  prefix: S.current.topic_lastReply,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatWidgetItem(
    BuildContext context,
    IconData icon,
    Widget child,
  ) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        child,
      ],
    );
  }

  Widget _buildStatItem(BuildContext context, IconData icon, String text) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildActions(BuildContext context, ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Row(
        children: [
          // 关闭按钮
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(S.current.common_close),
          ),

          const Spacer(),

          // 分享按钮
          IconButton(
            onPressed: () {
              final user = ref.read(currentUserProvider).value;
              final prefs = ref.read(preferencesProvider);
              final url = ShareUtils.buildShareUrl(
                path: '/t/topic/${topic.id}',
                username: user?.username,
                anonymousShare: prefs.anonymousShare,
              );
              SharePlus.instance.share(ShareParams(text: url));
            },
            icon: const Icon(Symbols.share_rounded, size: 20),
            tooltip: S.current.common_share,
          ),

          const SizedBox(width: 8),

          // 打开按钮
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              widget.onOpen?.call();
            },
            icon: const Icon(Symbols.open_in_new_rounded, size: 18),
            label: Text(S.current.common_viewDetails),
          ),
        ],
      ),
    );
  }

  Widget _buildCustomActions(BuildContext context, ThemeData theme) {
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      elevation: 8,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: widget.actions!.asMap().entries.map((entry) {
          final index = entry.key;
          final action = entry.value;
          final color = action.color ?? theme.colorScheme.onSurface;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (index > 0)
                Divider(
                  height: 0.5,
                  thickness: 0.5,
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.4,
                  ),
                ),
              InkWell(
                onTap: () {
                  Navigator.of(context).pop();
                  action.onTap();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(action.icon, size: 20, color: color),
                      const SizedBox(width: 12),
                      Text(
                        action.label,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildCategoryDot(Category category) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: _parseColor(category.color),
        shape: BoxShape.circle,
      ),
    );
  }

  Color _parseColor(String hex) {
    hex = hex.replaceAll('#', '');
    if (hex.length == 6) {
      return Color(int.parse('0xFF$hex'));
    }
    return Colors.grey;
  }
}
