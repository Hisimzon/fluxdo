import 'package:flutter/material.dart' show MaterialRectArcTween;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// 控制哪个 Hero tag 对应的图片应该在底层页面隐藏
/// 用于解决 opaque: false 路由中 Hero 切换不更新的问题
class HeroVisibilityController extends ChangeNotifier {
  HeroVisibilityController._();
  static final HeroVisibilityController instance = HeroVisibilityController._();

  String? _hiddenHeroTag;
  bool _isPopping = false;
  bool _notifyScheduled = false;

  /// 源端缩略图注册表:heroTag → 挂载中的 BuildContext。
  /// 查看器翻页时借此把源缩略图滚进可视区,保证 pop 时 Hero 有目的地。
  final Map<String, BuildContext> _sources = {};

  /// 退场时查看器里图片的**实际可见矩形**(全局坐标),放大态即放大后的
  /// 矩形。由查看器在 pop 前写入,源端 Hero 的 createRectTween 以它作
  /// 飞行起点 —— 这样「放大 → 缩略图」是 Hero 飞行本身的一段连续插值,
  /// 而不是先把画面归位到 contain 再起飞(那会看到「大图先变小图,再播
  /// 返回动画」两段动作,即用户所指的膈应感)。参考 Telegram PhotoViewer
  /// closePhoto:animationValues[0] 直接取当前 scale/translation 作起点。
  ///
  /// null = 未放大或无快照,Hero 走默认布局盒子几何(与旧行为一致)。
  Rect? _exitFlightRect;
  Rect? get exitFlightRect => _exitFlightRect;
  void setExitFlightRect(Rect? rect) => _exitFlightRect = rect;

  /// 源页注册的"按 heroTag 滚到附近"能力(段级粗滚,滚后源缩略图
  /// 构建并注册,再由 [ensureSourceVisible] 二次精确化)。
  Future<void> Function(String heroTag)? sourceScrollResolver;

  /// 当前应该隐藏的 hero tag
  String? get hiddenHeroTag => _hiddenHeroTag;

  /// 是否正在 pop 飞行结束
  bool get isPopping => _isPopping;

  /// 源缩略图挂载时注册(HeroImage 调用)
  void registerSource(String tag, BuildContext context) {
    _sources[tag] = context;
  }

  /// 源缩略图卸载时注销;校验 context 匹配,避免同 tag 新实例先注册、
  /// 旧实例后 dispose 时误删新注册。
  void unregisterSource(String tag, BuildContext context) {
    if (identical(_sources[tag], context)) {
      _sources.remove(tag);
    }
  }

  /// 把 [tag] 对应的源缩略图滚进可视区(供查看器翻页时预滚,
  /// 保证之后任意 pop 路径 Hero 都能飞回原位)。
  ///
  /// 失败静默:降级 = pop 时无飞行,整页渐隐。
  Future<void> ensureSourceVisible(String tag) async {
    try {
      if (_tryEnsureVisible(tag)) return;
      // 未注册(源缩略图已被列表回收):请求源页段级粗滚,
      // 等它构建注册后再精确化一次。
      final resolver = sourceScrollResolver;
      if (resolver == null) return;
      await resolver(tag);
      _tryEnsureVisible(tag);
    } catch (_) {
      // 静默降级
    }
  }

  bool _tryEnsureVisible(String tag) {
    final context = _sources[tag];
    if (context == null || !context.mounted) return false;
    Scrollable.ensureVisible(
      context,
      alignment: 0.5,
      duration: Duration.zero,
    );
    return true;
  }

  /// 设置当前应该隐藏的 hero tag（静默版，不触发通知）
  /// 用于 initState 中初始化，避免构建期间触发 rebuild
  void setHiddenTagSilent(String? tag) {
    _hiddenHeroTag = tag;
    _isPopping = false;
  }

  /// 设置当前应该隐藏的 hero tag（带通知）
  void setHiddenTag(String? tag) {
    if (_hiddenHeroTag == tag && !_isPopping) return;
    _hiddenHeroTag = tag;
    _isPopping = false;
    _safeNotify();
  }

  /// 宣告「本次关闭的退场已经开始」:源端缩略图立即恢复可见,好让
  /// Hero 飞行体有个落点、飞行体撤走时那个位置不是空洞。
  ///
  /// **不可依赖「pop 方向的 shuttle 被构建过」**。曾经的实现是在
  /// `flightShuttleBuilder` 的 `direction == pop` 分支里挂动画监听来调
  /// 本方法,但 push 飞行未结束就被 pop 打断时(用户连点两下、开图立刻
  /// 返回),框架走 `_HeroFlight.divert` 的 push→pop 分支,它只换
  /// `_proxyAnimation.parent` 与 `heroRectTween`,**不清 `shuttle`**
  /// (`heroes.dart`:`shuttle ??= manifest.shuttleBuilder(...)`)——
  /// shuttleBuilder 全程只以 push 方向被调用一次,那个监听器从未注册,
  /// `_isPopping` 恒 false ⇒ 源端 Opacity 锁死在 0 ⇒ 飞行体撤走后缩略图
  /// 位置是空洞,直到 [clear] 的 post-frame 才恢复 = 用户看到的黑闪。
  /// 实测:飞完再 pop 时 shuttle=[push, pop]、isPopping=true;中途打断
  /// 时 shuttle=[push]、isPopping=false。
  ///
  /// 故改由查看器在路由动画转 reverse / 手势置位时直接调用 —— 这两件事
  /// 与「是否新建 shuttle」无关,打断路径同样成立。
  void startPopping() {
    if (_isPopping) return;
    _isPopping = true;
    notifyListeners();
  }

  /// 清除所有状态(dispose 时调用)。
  ///
  /// 必须 post-frame 异步通知:
  /// - 如果 push Hero 飞行被中断 + viewer pop 没有完整 startPopping flow,
  ///   _hiddenHeroTag 还停留在最后 setHidden 的值,source 的 Opacity 锁在 0
  /// - 同步 notifyListeners 在 dispose 阶段会触发 widget tree 锁定异常
  /// - 走 _safeNotify(post-frame callback),帧结束后才通知 source rebuild
  void clear() {
    _hiddenHeroTag = null;
    _isPopping = false;
    _exitFlightRect = null;
    _safeNotify();
  }

  /// 统一延迟到帧结束后通知，避免在 build/dispose/动画期间触发 rebuild
  void _safeNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      notifyListeners();
    });
  }
}

/// **所有指向图片查看器的源端 Hero 都必须把它挂到 `createRectTween`。**
///
/// 放大态返回时飞行起点要用查看器发布的 [HeroVisibilityController
/// .exitFlightRect](含缩放与平移的实际可见矩形),而不是查看器的布局盒子
/// (全屏)。否则放大后的画面远大于布局盒子,观感是「大图瞬间变成小图,然后
/// 才播返回动画」两段动作,而不是一段连续插值。参考 Telegram
/// PhotoViewer.closePhoto:animationValues[0] 直接取当前 scale/translation。
///
/// 未放大时 exitFlightRect 为 null → 走框架默认几何(MaterialRectArcTween)。
///
/// **为什么抽成共享函数**:这段逻辑原先各处各写一份,漏一处就少一处效果 ——
/// 真机先后暴露过轮播、聊天图片放大后返回「大图瞬间变小再播动画」;排查时
/// 发现 6 个源端里只有 2 个有它(网格瓦片、正文单图、用户头像也都缺)。
/// 源端 Hero 的周边结构各不相同(HeroImage 带 Opacity+placeholder、轮播带
/// AspectRatio、聊天/头像是裸 Hero),但**飞行起点的口径必须一致**,故只共享
/// 这一个点。
///
/// 新增任何指向查看器的 Hero 都要挂上;
/// `test/widgets/viewer_hero_rect_tween_coverage_test.dart` 扫源码兜底。
Tween<Rect?> viewerHeroRectTween(Rect? begin, Rect? end) {
  final zoomed = HeroVisibilityController.instance.exitFlightRect;
  if (zoomed == null) {
    return MaterialRectArcTween(begin: begin, end: end);
  }
  // pop 方向:begin=查看器端(布局盒子)→ 换成放大后的可见矩形;
  // end=源端缩略图,保持不动。push 方向 exitFlightRect 为 null(仅退场时
  // 发布),不受影响。
  return RectTween(begin: zoomed, end: end);
}
