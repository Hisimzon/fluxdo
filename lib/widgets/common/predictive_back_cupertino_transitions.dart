// 拷贝自 Flutter 3.44 material/predictive_back_page_transitions_builder.dart
// (BSD 许可,版权归 The Flutter Authors)。
//
// 拷贝原因:官方 PredictiveBackPageTransitionsBuilder 的非手势降级转场
// 硬编码 FadeForwardsPageTransitionsBuilder(双页全屏 FadeTransition =
// 每帧两次全屏 saveLayer,Impeller 上 push/pop 必抽一串,生产日志定案),
// 且 push/按钮返回永远走降级 —— 无法在保留预测返回手势的同时避开它。
//
// 与原文件的差异(其余逐行保真,升级 Flutter 后 diff 上游同步):
// 1. 非手势降级从 FadeForwards 换成 CupertinoPageTransitionsBuilder,
//    fallbackColor 参数随之删除(Cupertino 无背景色);
// 2. transitionDuration 800ms → 400ms(Cupertino 时长),commit 动画
//    Interval 分母同步改为 400 → commit 仍是完整 400ms(与 Android
//    原生一致);
// 3. 只保留 shared-element 变体(fullscreen 变体未使用,未拷贝);
// 4. 预测返回判定从单独的 popGestureInProgress 收紧为「且 phase 非
//    idle」,并在手势窗口结束时把 phase 归位 —— 原版降级是 FadeForwards,
//    树里没有拖拽手势源;换 Cupertino 降级后,app 内 iOS 式拖拽返回
//    (边缘/全屏)同样置位 popGestureInProgress,原判定会把跟手平移误
//    渲染成预测返回的缩放预览。预测返回必经 handleStartBackGesture
//    (phase → start),以此区分手势来源。
// 5. 文件尾新增 [buildPredictiveBackPageTransitions](上游没有):给不走
//    PageTransitionsTheme 的 PageRouteBuilder 自定义转场补挂预测返回,
//    追加在上游内容之后,不打断上游类排布。
// 6. 预测返回期间冻结下层路由的 Cupertino secondaryAnimation。否则
//    当前页缩小后,下层页仍停在向左偏移 1/3 屏的位置,右侧会露出
//    Navigator 的黑色背景。
// 7. 手势中途 Activity 进后台(挂后台/锁屏)时代打 cancel。系统不为
//    被打断的手势补发 commit/cancel,否则 userGestureInProgress 计数
//    永不归零 → popGestureEnabled 恒 false,回前台后预测返回永久失效
//    (手势无人认领,退场无动画),手势期 flag 也卡死。
// 8. 转场期静默认领:入场未完成、或根路由压着退场中的上一划
//    (isFirst 被 popGestureEnabled 排除)时,快速再划全员拒绝,引擎
//    fallback 整树缩小露黑边;回调若仍注册,commit 还会兜到
//    SystemNavigator.pop 关 app。栈顶 detector 静默认领:不驱动路由
//    动画,commit 非根排队 maybePop、根路由吞掉,cancel 弃认领。
// 9. 收尾事件按 phase 门控:binding 的认领者列表 commit/cancel 后不
//    清空(下次 start 才清),原生 onStop 每次锁屏广播的
//    cancelBackGesture 会打到上一次手势的陈旧认领者,无配对 start 的
//    handleCancelBackGesture 令 userGesture 计数下溢,预测返回全局
//    静默失效(浮层不查计数故独活)。phase 非 start/update 一律忽略。
// 10. 全局手势活跃标记 [predictiveBackGestureActive](上游没有):
//    BackDispatchHold 据此在手势进行中不撤 OnBackInvokedCallback
//    注册 —— 否则第二划拖过退场窗口边界时被中途注销,系统当场接管
//    出黑底。认领(含静默)置 true,commit/cancel/锁屏代打清 false。
// 11. 差异点 6 的冻结分支必须带铺底(ColoredBox surface)。手势期 flag
//    按 Navigator 存,同一 Navigator 下所有 phase==idle 的路由都进冻结
//    分支,直接 return child 剥掉了 Cupertino 转场的背景填充 → 预测
//    预览缩小后,框外/边缘无人铺底,露出 Navigator 底色纯黑(连划黑底
//    实测几何:框内两页重影、框外全黑)。opaque:false 路由不垫(会挡
//    住其下本该可见的页面)。
//
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:ui' show clampDouble;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

final Expando<ValueNotifier<bool>> _predictiveBackGestureStates =
    Expando<ValueNotifier<bool>>('predictive back gesture state');

/// 差异点 10:预测返回手势是否活跃(任一 detector 已认领,含静默
/// 认领)。BackDispatchHold 在手势进行中保持 OnBackInvokedCallback
/// 注册不被撤销 —— 引擎收到 setFrameworkHandlesBack(false) 会立刻
/// unregister,进行中的手势被截断,后续 progress/commit 直接改由
/// 系统接管(整窗缩小黑底)。
final ValueNotifier<bool> predictiveBackGestureActive =
    ValueNotifier<bool>(false);

ValueNotifier<bool>? _predictiveBackGestureStateFor(PageRoute<dynamic> route) {
  final navigator = route.navigator;
  if (navigator == null) return null;
  return _predictiveBackGestureStates[navigator] ??= ValueNotifier<bool>(false);
}

/// Android 预测返回 + Cupertino 降级的页面转场。
///
/// 预测返回手势(Android U+)期间与系统手势联动显示 shared-element 预览;
/// 其余导航(push、按钮/程序化 pop、其它平台)走 Cupertino 滑动转场。
class PredictiveBackCupertinoPageTransitionsBuilder
    extends PageTransitionsBuilder {
  const PredictiveBackCupertinoPageTransitionsBuilder();

  @override
  Duration get transitionDuration => const Duration(
    milliseconds: _PredictiveBackSharedElementPageTransitionState
        ._kTransitionMilliseconds,
  );

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _PredictiveBackGestureDetector(
      route: route,
      builder:
          (
            BuildContext context,
            _PredictiveBackPhase phase,
            PredictiveBackEvent? startBackEvent,
            PredictiveBackEvent? currentBackEvent,
          ) {
            final predictiveBackState = _predictiveBackGestureStateFor(route);

            Widget buildTransition(bool predictiveBackInProgress) {
              // Cupertino 的 secondaryAnimation 会把上一页向左推出约
              // 1/3 屏。预测返回缩小当前页时,上一页应作为静态背景铺满。
              // 判定「未参与手势」必须用 phase == idle(下层路由的
              // detector 从未认领手势,phase 恒为 idle),不能用
              // !route.isCurrent:commit 的 navigator.pop() 同步把被弹
              // 路由翻成非 current,而手势 flag 要等收尾动画播完才清,
              // 按 isCurrent 判定会把 commit 收尾动画整段吞成静态贴图。
              //
              // 差异点 12:冻结必须**带铺底**。手势期 flag 按 Navigator
              // 存(Expando 键是 navigator),同一 Navigator 下所有
              // phase==idle 的路由都会进本分支 —— 包括预览缩小后露出
              // 边缘的下层/根路由。直接 return child 等于剥掉 Cupertino
              // 转场的背景填充,预览框外与边缘无人铺底 → 露出 Navigator
              // 底色纯黑(连划黑底实测几何:缩小框内两页重影、框外全黑)。
              // 用 ColoredBox 垫主题 surface 后,任何露出区域都是主题色。
              if (predictiveBackInProgress &&
                  phase == _PredictiveBackPhase.idle) {
                // 透明路由(opaque:false)不垫:会挡住其下方本该可见的页面
                if (!route.opaque) return child;
                return ColoredBox(
                  color: Theme.of(context).colorScheme.surface,
                  child: child,
                );
              }

              // Only do a predictive back transition when the user is performing a
              // pop gesture. Otherwise, for things like button presses or other
              // programmatic navigation, fall back to
              // CupertinoPageTransitionsBuilder.
              //
              // 差异点(文件头第 4 条):app 内 iOS 式拖拽返回同样置位
              // popGestureInProgress,但不会触发 handleStartBackGesture,
              // phase 仍为 idle —— 交给 Cupertino 分支跟手渲染。
              if (route.popGestureInProgress &&
                  phase != _PredictiveBackPhase.idle) {
                return _PredictiveBackSharedElementPageTransition(
                  isDelegatedTransition: true,
                  animation: animation,
                  phase: phase,
                  secondaryAnimation: secondaryAnimation,
                  startBackEvent: startBackEvent,
                  currentBackEvent: currentBackEvent,
                  child: child,
                );
              }

              return const CupertinoPageTransitionsBuilder().buildTransitions(
                route,
                context,
                animation,
                secondaryAnimation,
                child,
              );
            }

            if (predictiveBackState == null) {
              return buildTransition(false);
            }
            return ValueListenableBuilder<bool>(
              valueListenable: predictiveBackState,
              builder: (_, inProgress, _) => buildTransition(inProgress),
            );
          },
    );
  }
}

typedef _PredictiveBackGestureDetectorWidgetBuilder =
    Widget Function(
      BuildContext context,
      _PredictiveBackPhase phase,
      PredictiveBackEvent? startBackEvent,
      PredictiveBackEvent? currentBackEvent,
    );

/// The phases of a predictive back gesture.
enum _PredictiveBackPhase {
  /// There is no active predictive back gesture in progress.
  idle,

  /// The user pointer has contacted the screen.
  start,

  /// The user pointer has moved.
  update,

  /// The user pointer has released in a position in which Android has
  /// determined that the back gesture is successful and the current route
  /// should be popped.
  commit,

  /// The user pointer has released in a position in which Android has
  /// determined that the back gesture should be canceled and the original route
  /// should be shown.
  cancel,
}

class _PredictiveBackGestureDetector extends StatefulWidget {
  const _PredictiveBackGestureDetector({
    required this.route,
    required this.builder,
  });

  final _PredictiveBackGestureDetectorWidgetBuilder builder;
  final PageRoute<dynamic> route;

  @override
  State<_PredictiveBackGestureDetector> createState() =>
      _PredictiveBackGestureDetectorState();
}

class _PredictiveBackGestureDetectorState
    extends State<_PredictiveBackGestureDetector>
    with WidgetsBindingObserver {
  bool _ownsPredictiveBackGesture = false;

  // 差异点(文件头第 7 条):后台/锁屏打断手势后,系统不会为这条
  // 手势补发 commit/cancel。置位后忽略迟到的收尾事件,直到下一次
  // startBackGesture 重新认领。
  bool _gestureForceCancelled = false;

  /// True when the predictive back gesture is enabled.
  bool get _isEnabled {
    return widget.route.isCurrent && widget.route.popGestureEnabled;
  }

  /// 差异点(文件头第 8 条,修订):退场转场窗口内的兜底认领。
  ///
  /// 非根路由不需要:B 压着退场中的 C 时,B 自己的 animation 已
  /// completed,popGestureEnabled 为 true,正常路径即可认领。
  /// 真正无人认领的是两种窗口:
  /// - 当前路由自己的入场动画未完成(push 进行中再划);
  /// - **根路由 + 上方路由退场中**(secondaryAnimation 非 dismissed):
  ///   isFirst 被 popGestureEnabled 排除,全员拒绝 → 引擎/系统接管
  ///   出黑边;若回调仍注册,commit 还会兜底到 SystemNavigator.pop
  ///   直接关 app。
  /// 静默认领:不驱动路由动画;commit 时根路由吞掉(退场中的第二划
  /// 意图是"回上一页",上一页已在退场,不该再退成关 app),非根排队
  /// maybePop;cancel 弃认领。
  bool get _shouldClaimDuringTransition {
    final route = widget.route;
    // 注意:不检查 popDisposition。双击退出模式下根路由 PopScope
    // canPop:false → popDisposition == doNotPop,若以此拒绝武装,
    // 退场窗口的第二划全员不认领 → 系统直接关 Activity(黑边+app
    // 进后台,logcat 实证 2026-08-11)。静默认领的 commit 走
    // maybePop,PopScope 的拦截语义在 maybePop 里天然生效,认领
    // 本身不需要这个前置。
    if (!route.isCurrent || route.willHandlePopInternally) {
      return false;
    }
    final bool ownEntranceInFlight = !route.animation!.isCompleted;
    final bool aboveExitInFlight =
        route.secondaryAnimation!.status != AnimationStatus.dismissed;
    return ownEntranceInFlight || aboveExitInFlight;
  }

  /// 本次认领是「转场期静默认领」(不驱动路由动画,commit 只 pop)
  bool _silentClaim = false;

  _PredictiveBackPhase get phase => _phase;
  _PredictiveBackPhase _phase = _PredictiveBackPhase.idle;
  set phase(_PredictiveBackPhase phase) {
    if (_phase != phase && mounted) {
      setState(() => _phase = phase);
    }
  }

  /// The back event when the gesture first started.
  PredictiveBackEvent? get startBackEvent => _startBackEvent;
  PredictiveBackEvent? _startBackEvent;
  set startBackEvent(PredictiveBackEvent? startBackEvent) {
    if (_startBackEvent != startBackEvent && mounted) {
      setState(() => _startBackEvent = startBackEvent);
    }
  }

  /// The most recent back event during the gesture.
  PredictiveBackEvent? get currentBackEvent => _currentBackEvent;
  PredictiveBackEvent? _currentBackEvent;
  set currentBackEvent(PredictiveBackEvent? currentBackEvent) {
    if (_currentBackEvent != currentBackEvent && mounted) {
      setState(() => _currentBackEvent = currentBackEvent);
    }
  }

  // Begin WidgetsBindingObserver.

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (backEvent.isButtonEvent) {
      return false;
    }
    if (!_isEnabled) {
      // 差异点 8:转场期静默认领,防引擎 fallback 黑边
      if (_shouldClaimDuringTransition) {
        _gestureForceCancelled = false;
        _silentClaim = true;
        predictiveBackGestureActive.value = true;
        return true;
      }
      return false;
    }

    _gestureForceCancelled = false;
    _silentClaim = false;
    phase = _PredictiveBackPhase.start;
    _ownsPredictiveBackGesture = true;
    predictiveBackGestureActive.value = true;
    _predictiveBackGestureStateFor(widget.route)?.value = true;
    widget.route.handleStartBackGesture(progress: 1 - backEvent.progress);
    startBackEvent = currentBackEvent = backEvent;
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (_gestureForceCancelled || _silentClaim) return;
    phase = _PredictiveBackPhase.update;

    widget.route.handleUpdateBackGestureProgress(
      progress: 1 - backEvent.progress,
    );
    currentBackEvent = backEvent;
  }

  @override
  void handleCancelBackGesture() {
    predictiveBackGestureActive.value = false;
    if (_gestureForceCancelled) return;
    if (_silentClaim) {
      _silentClaim = false;
      return;
    }
    // 差异点 9:只在手势活跃期收 cancel。binding 的认领者列表在
    // commit/cancel 后不清空(仅下次 start 时清),原生 onStop 每次
    // 锁屏广播的 cancelBackGesture 会打到上一次手势的认领者上;
    // 不设门则 route.handleCancelBackGesture → didStopUserGesture
    // 无配对 start,计数器下溢成负,userGestureInProgress 永久
    // false,预测返回渲染全灭(浮层 handler 有 _gestureActive 同款
    // 门控,故「全 app 坏、唯独浮层活」)。
    if (phase != _PredictiveBackPhase.start &&
        phase != _PredictiveBackPhase.update) {
      return;
    }
    phase = _PredictiveBackPhase.cancel;

    widget.route.handleCancelBackGesture();
    startBackEvent = currentBackEvent = null;
  }

  @override
  void handleCommitBackGesture() {
    predictiveBackGestureActive.value = false;
    if (_gestureForceCancelled) return;
    if (_silentClaim) {
      _silentClaim = false;
      // 转场期 commit:排队再退一层(等本帧转场态结算,直接 pop 会
      // 撞上仍在 popping 的上一路由)。用 maybePop:PopScope 的
      // doNotPop(双击退出拦截等)在此天然生效;根路由 maybePop 是
      // no-op(除 LocalHistory 外),自动退化为「吞掉」。
      final navigator = widget.route.navigator;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        navigator?.maybePop();
      });
      return;
    }
    // 差异点 9:同 cancel,陈旧认领者不得响应伪事件
    if (phase != _PredictiveBackPhase.start &&
        phase != _PredictiveBackPhase.update) {
      return;
    }
    phase = _PredictiveBackPhase.commit;

    widget.route.handleCommitBackGesture();
    startBackEvent = currentBackEvent = null;
  }

  // 差异点(文件头第 7 条):Activity 进后台(挂后台/锁屏)会打断
  // 进行中的预测返回手势,且系统不再补发 commit/cancel。若不收尾,
  // navigator.userGestureInProgress 计数永不归零 → popGestureEnabled
  // 恒 false,回前台后所有预测返回被静默拒绝(手势无人认领,系统
  // 只能整 app 缩走/无动画),且手势期 flag 卡 true 让下层路由永远
  // 渲染成静态背景。这里代打 cancel 把手势态完整归零。
  // hidden/paused 会先后各触发一次,_gestureForceCancelled 防重入
  // (_ownsPredictiveBackGesture 要等取消动画播完才清,挡不住)。
  //
  // 只在 phase 为 start/update(手势活跃未收尾)时代打:commit/cancel
  // 之后 _ownsPredictiveBackGesture 仍为 true(等收尾动画),这个窗口
  // 内锁屏若再代打 cancel,会与 commit/cancel 自己挂的动画完成回调
  // 各触发一次 didStopUserGesture → 计数下溢(release 无 assert,
  // 计数变 -1),之后 userGestureInProgress 永久 off-by-one 恒 false,
  // 预测返回全局静默失效 —— 恰是本修复要防的症状,别自己造一遍。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused) {
      return;
    }
    // 转场期静默认领没碰路由动画,锁屏只需弃掉认领
    if (_silentClaim) {
      _silentClaim = false;
      predictiveBackGestureActive.value = false;
      return;
    }
    if (!_ownsPredictiveBackGesture || _gestureForceCancelled) return;
    if (phase != _PredictiveBackPhase.start &&
        phase != _PredictiveBackPhase.update) {
      return;
    }

    _gestureForceCancelled = true;
    predictiveBackGestureActive.value = false;
    phase = _PredictiveBackPhase.cancel;
    widget.route.handleCancelBackGesture();
    startBackEvent = currentBackEvent = null;
  }

  // End WidgetsBindingObserver.

  // 差异点(文件头第 4 条):手势窗口关闭(didStopUserGesture)时把 phase
  // 归位 idle。否则上一次预测返回 cancel 残留的 phase 会让之后的 app 内
  // 拖拽返回(同样置位 popGestureInProgress)整程误判成预测返回。
  ValueListenable<bool>? _userGestureInProgress;

  void _handleUserGestureChanged() {
    if (_userGestureInProgress?.value == false) {
      phase = _PredictiveBackPhase.idle;
      _clearPredictiveBackGesture();
    }
  }

  void _clearPredictiveBackGesture() {
    if (!_ownsPredictiveBackGesture) return;
    _ownsPredictiveBackGesture = false;
    _predictiveBackGestureStateFor(widget.route)?.value = false;
  }

  void _subscribeUserGesture() {
    final notifier = widget.route.navigator?.userGestureInProgressNotifier;
    if (identical(notifier, _userGestureInProgress)) {
      return;
    }
    _userGestureInProgress?.removeListener(_handleUserGestureChanged);
    _userGestureInProgress = notifier;
    _userGestureInProgress?.addListener(_handleUserGestureChanged);
  }

  @override
  void didUpdateWidget(covariant _PredictiveBackGestureDetector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.route, widget.route) &&
        _ownsPredictiveBackGesture) {
      _ownsPredictiveBackGesture = false;
      _predictiveBackGestureStateFor(oldWidget.route)?.value = false;
    }
    _subscribeUserGesture();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscribeUserGesture();
  }

  @override
  void dispose() {
    // dispose 可能发生在树锁定期间(被弹路由退场动画结束帧),同步
    // notify 手势 flag 会命中 markNeedsBuild-when-locked 断言;
    // 延迟到帧后清理。
    if (_ownsPredictiveBackGesture || _silentClaim) {
      _ownsPredictiveBackGesture = false;
      _silentClaim = false;
      final route = widget.route;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _predictiveBackGestureStateFor(route)?.value = false;
        predictiveBackGestureActive.value = false;
      });
    }
    _userGestureInProgress?.removeListener(_handleUserGestureChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final _PredictiveBackPhase effectivePhase =
        widget.route.popGestureInProgress ? phase : _PredictiveBackPhase.idle;
    return widget.builder(
      context,
      effectivePhase,
      startBackEvent,
      currentBackEvent,
    );
  }
}

/// Android's predictive back page shared element transition.
///
/// See also:
///
///  * <https://developer.android.com/design/ui/mobile/guides/patterns/predictive-back#shared-element-transition>,
///    which is the Android spec for this transition.
class _PredictiveBackSharedElementPageTransition extends StatefulWidget {
  const _PredictiveBackSharedElementPageTransition({
    required this.isDelegatedTransition,
    required this.animation,
    required this.secondaryAnimation,
    required this.phase,
    required this.startBackEvent,
    required this.currentBackEvent,
    required this.child,
  });

  final bool isDelegatedTransition;
  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final _PredictiveBackPhase phase;
  final PredictiveBackEvent? startBackEvent;
  final PredictiveBackEvent? currentBackEvent;
  final Widget child;

  @override
  State<_PredictiveBackSharedElementPageTransition> createState() =>
      _PredictiveBackSharedElementPageTransitionState();
}

class _PredictiveBackSharedElementPageTransitionState
    extends State<_PredictiveBackSharedElementPageTransition>
    with SingleTickerProviderStateMixin {
  // Constants as per the motion specs
  // https://developer.android.com/design/ui/mobile/guides/patterns/predictive-back#motion-specs
  static const double _kMinScale = 0.90;
  static const double _kDivisionFactor = 20.0;
  static const double _kMargin = 8.0;
  static const double _kYPositionFactor = 0.1;

  // The duration of the commit transition.
  //
  // This is not the same as the route's transitionDuration, so an Interval is
  // used. With both at 400ms (Cupertino duration), the interval spans the
  // whole animation.
  //
  // Eyeballed on a Pixel 9 running Android 16.
  static const int _kCommitMilliseconds = 400;

  // 降级转场为 Cupertino,route 时长随之为 400ms(原文件用 FadeForwards
  // 的 800ms)。commit Interval 分母同步 → commit 仍是完整 400ms。
  static const int _kTransitionMilliseconds = 400;
  static const Curve _kCurve = Curves.easeInOutCubicEmphasized;
  static const Interval _kCommitInterval = Interval(
    0.0,
    _kCommitMilliseconds / _kTransitionMilliseconds,
    curve: _kCurve,
  );

  // A fallback corner radius used when the display corner radii are
  // unavailable (e.g., on Android API levels below 31, iOS, and other
  // platforms). This is a best-guess value that looks reasonable on most
  // devices.
  // See https://github.com/flutter/flutter/issues/97349.
  static const double _kDeviceBorderRadius = 32.0;

  // Provides a smooth transition between the default radius and the
  // _kDeviceBorderRadius, when the display corner radii are unavailable.
  final Tween<double> _borderRadiusTween = Tween<double>(
    begin: 0.0,
    end: _kDeviceBorderRadius,
  );

  // The route fades out after commit.
  final Tween<double> _opacityTween = Tween<double>(begin: 1.0, end: 0.0);

  // The route shrinks during the gesture and animates back to normal after
  // commit.
  final Tween<double> _scaleTween = Tween<double>(begin: 1.0, end: _kMinScale);

  // An animation that stays constant at zero before the commit, and after the
  // commit goes from zero to one.
  final ProxyAnimation _commitAnimation = ProxyAnimation();

  // An animation that goes from zero to a maximum of one during a predictive
  // back gesture, and then at commit, it goes from its current value to zero.
  // Used for animations that follow the gesture and then animate back to their
  // original value after commit.
  final ProxyAnimation _bounceAnimation = ProxyAnimation();
  double _lastBounceAnimationValue = 0.0;

  // An animation that proxies to widget.animation during the gesture and then
  // to _commitAnimation after the commit. So, it goes from zero to a maximum of
  // one before commit, and then after commit goes from zero to one again.
  final ProxyAnimation _animation = ProxyAnimation();

  /// The same as widget.animation but with a curve applied.
  CurvedAnimation? _curvedAnimation;

  /// The reverse of _curvedAnimation.
  CurvedAnimation? _curvedAnimationReversed;

  late Animation<Offset> _positionAnimation;

  Offset _lastDrag = Offset.zero;

  // This isn't done as an animation because it's based on the vertical drag
  // amount, not the progression of the back gesture like widget.animation is.
  double _getYShiftPosition(double screenHeight) {
    final double startTouchY = widget.startBackEvent?.touchOffset?.dy ?? 0;
    final double currentTouchY = widget.currentBackEvent?.touchOffset?.dy ?? 0;

    final double yShiftMax = (screenHeight / _kDivisionFactor) - _kMargin;

    final double rawYShift = currentTouchY - startTouchY;
    final double easedYShift =
        // This curve was eyeballed on a Pixel 9 running Android 16.
        Curves.easeOut.transform(
          clampDouble(rawYShift.abs() / screenHeight, 0.0, 1.0),
        ) *
        rawYShift.sign *
        yShiftMax;

    return clampDouble(easedYShift, -yShiftMax, yShiftMax);
  }

  void _updateAnimations(Size screenSize) {
    _animation.parent = switch (widget.phase) {
      _PredictiveBackPhase.commit => _curvedAnimationReversed,
      _ => widget.animation,
    };

    _bounceAnimation.parent = switch (widget.phase) {
      _PredictiveBackPhase.commit => Tween<double>(
        begin: 0.0,
        end: _lastBounceAnimationValue,
      ).animate(_curvedAnimation!),
      _ => ReverseAnimation(widget.animation),
    };

    _commitAnimation.parent = switch (widget.phase) {
      _PredictiveBackPhase.commit => _animation,
      _ => kAlwaysDismissedAnimation,
    };

    final double xShift = (screenSize.width / _kDivisionFactor) - _kMargin;
    _positionAnimation = _animation.drive(switch (widget.phase) {
      _PredictiveBackPhase.commit => Tween<Offset>(
        begin: _lastDrag,
        end: Offset(screenSize.height * _kYPositionFactor, 0.0),
      ),
      _ => Tween<Offset>(
        // The y position before commit is given by the vertical drag, not by an
        // animation.
        begin: switch (widget.currentBackEvent?.swipeEdge) {
          SwipeEdge.left => Offset(
            xShift,
            _getYShiftPosition(screenSize.height),
          ),
          SwipeEdge.right => Offset(
            -xShift,
            _getYShiftPosition(screenSize.height),
          ),
          null => Offset(xShift, _getYShiftPosition(screenSize.height)),
        },
        end: Offset.zero,
      ),
    });
  }

  void _updateCurvedAnimations() {
    _curvedAnimation?.dispose();
    _curvedAnimationReversed?.dispose();
    _curvedAnimation = CurvedAnimation(
      parent: widget.animation,
      curve: _kCommitInterval,
    );
    _curvedAnimationReversed = CurvedAnimation(
      parent: ReverseAnimation(widget.animation),
      curve: _kCommitInterval,
    );
  }

  @override
  void didUpdateWidget(_PredictiveBackSharedElementPageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.animation != oldWidget.animation) {
      _updateCurvedAnimations();
    }
    if (widget.phase != oldWidget.phase &&
        widget.phase == _PredictiveBackPhase.commit) {
      _updateAnimations(MediaQuery.sizeOf(context));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateCurvedAnimations();
    _updateAnimations(MediaQuery.sizeOf(context));
  }

  @override
  void dispose() {
    _curvedAnimation!.dispose();
    _curvedAnimationReversed!.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.animation,
      builder: (BuildContext context, Widget? child) {
        _lastBounceAnimationValue = _bounceAnimation.value;
        return Transform.scale(
          scale: _scaleTween.evaluate(_bounceAnimation),
          child: Transform.translate(
            offset: switch (widget.phase) {
              _PredictiveBackPhase.commit => _positionAnimation.value,
              _ => _lastDrag = Offset(
                _positionAnimation.value.dx,
                _getYShiftPosition(MediaQuery.heightOf(context)),
              ),
            },
            child: Opacity(
              opacity: _opacityTween.evaluate(_commitAnimation),
              child: ClipRRect(
                borderRadius:
                    MediaQuery.displayCornerRadiiOf(context) ??
                    BorderRadius.circular(
                      _borderRadiusTween.evaluate(_bounceAnimation),
                    ),
                child: child,
              ),
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}

// —— 以下为本仓库追加,上游无对应物(差异点 5)——

/// 给 [PageRouteBuilder] 自定义转场补挂 Android 预测返回。
///
/// PageRouteBuilder 不走全局 PageTransitionsTheme,其转场树里没有
/// _PredictiveBackGestureDetector,预测返回手势无人认领 → 系统只能整
/// app 缩走。本函数在自定义转场外围补挂探测器:预测返回手势期间渲染
/// shared-element 预览,其余(push、按钮/程序化 pop、其它平台)保持
/// 路由原有的 [fallbackBuilder] 转场。
///
/// [useSharedElementPreview] = false 时仍认领手势(路由动画由手势进度
/// 驱动),但视觉沿用 [fallbackBuilder] —— 供 Hero 路由使用:预览的
/// 缩放/裁切会跟 Hero 飞行体打架,而认领手势恰恰是 Hero 跟手飞行的
/// 前提(HeroController 只为 user gesture 转场启动带
/// transitionOnUserGestures 标记的 Hero;不认领则系统整 app 缩走,
/// Hero 完全不飞)。两端 Hero 都需置 transitionOnUserGestures: true。
///
/// 判定与 [PredictiveBackCupertinoPageTransitionsBuilder] 同标准
/// (popGestureInProgress 且 phase 非 idle,见文件头差异点 4):这些
/// 路由今天没挂 app 内拖拽返回手势,但 fullscreen_swipe_back 等手势
/// 源置位的是 Navigator 级 userGestureInProgress,宽松判定会在共存时
/// 误判,统一收紧避免踩坑。
Widget buildPredictiveBackPageTransitions(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child, {
  bool useSharedElementPreview = true,
  required Widget Function(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  )
  fallbackBuilder,
}) {
  final route = ModalRoute.of(context);
  if (route is! PageRoute<dynamic>) {
    return fallbackBuilder(context, animation, secondaryAnimation, child);
  }

  return _PredictiveBackGestureDetector(
    route: route,
    builder:
        (
          BuildContext context,
          _PredictiveBackPhase phase,
          PredictiveBackEvent? startBackEvent,
          PredictiveBackEvent? currentBackEvent,
        ) {
          final predictiveBackState = _predictiveBackGestureStateFor(route);

          Widget buildTransition(bool predictiveBackInProgress) {
            // 同上方主题 builder:判定「未参与手势」用 phase == idle,
            // 不能用 !isCurrent(commit 的 pop 同步翻非 current,会把
            // 被弹路由自己的 commit 收尾动画吞掉)。
            // 差异点 12:冻结带铺底,否则露出区域是 Navigator 底色纯黑。
            // 本 helper 的路由多为 opaque:false(查看器等),铺底会挡住
            // 底层页面 —— 仅在不透明路由上垫。
            if (predictiveBackInProgress &&
                phase == _PredictiveBackPhase.idle) {
              if (!route.opaque) return child;
              return ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: child,
              );
            }
            if (useSharedElementPreview &&
                route.popGestureInProgress &&
                phase != _PredictiveBackPhase.idle) {
              return _PredictiveBackSharedElementPageTransition(
                isDelegatedTransition: true,
                animation: animation,
                phase: phase,
                secondaryAnimation: secondaryAnimation,
                startBackEvent: startBackEvent,
                currentBackEvent: currentBackEvent,
                child: child,
              );
            }

            // 手势期间落到这里(useSharedElementPreview: false):路由
            // 动画已被手势进度驱动,fallback 转场自然跟手。
            return fallbackBuilder(
              context,
              animation,
              secondaryAnimation,
              child,
            );
          }

          if (predictiveBackState == null) {
            return buildTransition(false);
          }
          return ValueListenableBuilder<bool>(
            valueListenable: predictiveBackState,
            builder: (_, inProgress, _) => buildTransition(inProgress),
          );
        },
  );
}
