import 'dart:ui' show lerpDouble;

import 'package:extended_image_lite/extended_image_lite.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/predictive_back_cupertino_transitions.dart';

/// 查看器退场缩放策略的机制层测试(与 _ImageViewerPageState 的
/// 松弛逻辑同构;不拉真图):
/// - 按钮 pop:reverse 首帧瞬时归位;
/// - 预测返回:手势进度驱动松弛(拖越多缩放越收拢),cancel 弹回
///   自动恢复原缩放,commit 残余 snap 后起飞。
class _ZoomRelaxHarness extends StatefulWidget {
  const _ZoomRelaxHarness({required this.controller});
  final ImageGestureController controller;

  @override
  State<_ZoomRelaxHarness> createState() => _ZoomRelaxHarnessState();
}

class _ZoomRelaxHarnessState extends State<_ZoomRelaxHarness> {
  ModalRoute<dynamic>? _route;
  double? _relaxStartScale;
  Offset? _relaxStartOffset;
  bool _relaxListening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _route)) {
      _route?.animation?.removeStatusListener(_onStatus);
      _route = route;
      _route?.animation?.addStatusListener(_onStatus);
    }
    _route?.navigator?.userGestureInProgressNotifier.addListener(_onGesture);
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.reverse) return;
    if (_relaxListening) return;
    final scale = widget.controller.details?.totalScale ?? 1.0;
    if (scale != 1.0) widget.controller.reset();
  }

  void _onGesture() {
    final nav = _route?.navigator;
    if (nav == null) return;
    if (nav.userGestureInProgress && (_route?.isCurrent ?? false)) {
      _beginRelax();
    } else if (!nav.userGestureInProgress) {
      _endRelax(restore: true);
    }
  }

  void _beginRelax() {
    if (_relaxListening) return;
    final details = widget.controller.details;
    final scale = details?.totalScale ?? 1.0;
    if (scale <= 1.0) return;
    _relaxStartScale = scale;
    _relaxStartOffset = details?.offset ?? Offset.zero;
    _relaxListening = true;
    _route?.animation?.addListener(_onTick);
    _onTick();
  }

  void _onTick() {
    final t = _route?.animation?.value ?? 1.0;
    final startScale = _relaxStartScale;
    if (startScale == null) return;
    final eased = Curves.easeOut.transform(1.0 - t.clamp(0.0, 1.0));
    widget.controller.details = GestureDetails(
      totalScale: lerpDouble(startScale, 1.0, eased),
      offset: Offset.lerp(_relaxStartOffset, Offset.zero, eased),
      userOffset: false,
      gestureDetails: widget.controller.details,
    );
  }

  void _endRelax({bool restore = false}) {
    if (!_relaxListening) return;
    _relaxListening = false;
    _route?.animation?.removeListener(_onTick);
    if (restore) _onTick();
    _relaxStartScale = null;
    _relaxStartOffset = null;
  }

  @override
  void dispose() {
    _endRelax();
    _route?.animation?.removeStatusListener(_onStatus);
    _route?.navigator?.userGestureInProgressNotifier
        .removeListener(_onGesture);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpViewer(
    WidgetTester tester,
    ImageGestureController controller,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                PageRouteBuilder<void>(
                  opaque: false,
                  transitionDuration: const Duration(milliseconds: 300),
                  reverseTransitionDuration: const Duration(milliseconds: 300),
                  pageBuilder: (_, _, _) =>
                      _ZoomRelaxHarness(controller: controller),
                  transitionsBuilder:
                      (context, animation, secondaryAnimation, child) =>
                          buildPredictiveBackPageTransitions(
                            context,
                            animation,
                            secondaryAnimation,
                            child,
                            transitionBuilder: (_, animation, _, child) =>
                                FadeTransition(
                                  opacity: animation,
                                  child: child,
                                ),
                          ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  void zoomTo(ImageGestureController controller, double scale) {
    controller.details = GestureDetails(
      totalScale: scale,
      offset: Offset.zero,
      gestureDetails: controller.details,
    );
  }

  Future<void> send(String method, [Map<String, Object?>? args]) {
    return binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/backgesture',
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
  }

  Map<String, Object?> gestureArgs(double progress) => {
    'touchOffset': <double>[10, 300],
    'progress': progress,
    'swipeEdge': 0,
  };

  testWidgets('程序化 pop:reverse 首帧缩放归位', (tester) async {
    final controller = ImageGestureController();
    addTearDown(controller.dispose);
    await pumpViewer(tester, controller);

    zoomTo(controller, 3.0);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    expect(controller.details!.totalScale, 1.0);
    await tester.pumpAndSettle();
  });

  testWidgets('预测返回:缩放随手势进度松弛,拖越多越收拢', (tester) async {
    final controller = ImageGestureController();
    addTearDown(controller.dispose);
    await pumpViewer(tester, controller);

    zoomTo(controller, 3.0);
    await send('startBackGesture', gestureArgs(0.0));
    await tester.pump();
    // 起点:未拖动,缩放保持
    expect(controller.details!.totalScale, closeTo(3.0, 0.01));

    await send('updateBackGestureProgress', gestureArgs(0.5));
    await tester.pump();
    final midScale = controller.details!.totalScale!;
    expect(midScale, lessThan(3.0), reason: '拖到一半应部分收拢');
    expect(midScale, greaterThan(1.0));

    await send('updateBackGestureProgress', gestureArgs(0.9));
    await tester.pump();
    expect(controller.details!.totalScale, lessThan(midScale),
        reason: '拖更多应更收拢(单调)');

    await send('commitBackGesture');
    await tester.pumpAndSettle();
    expect(controller.details!.totalScale, 1.0);
    expect(find.text('open'), findsOneWidget);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('真机姿势:低进度 fling commit,残余缩放随退场连续收拢无跳变',
      (tester) async {
    final controller = ImageGestureController();
    addTearDown(controller.dispose);
    await pumpViewer(tester, controller);

    zoomTo(controller, 3.0);
    await send('startBackGesture', gestureArgs(0.0));
    await tester.pump();
    // 轻甩:进度只到 0.15 就松手(真机常态)
    await send('updateBackGestureProgress', gestureArgs(0.15));
    await tester.pump();
    final atRelease = controller.details!.totalScale!;
    expect(atRelease, greaterThan(2.0), reason: '轻甩松手时缩放大部分还在');

    await send('commitBackGesture');
    await tester.pump();
    // commit 首帧:不得 snap(旧行为在这里一把打回 1.0 = 用户抱怨的突兀)
    final justCommitted = controller.details!.totalScale!;
    expect(justCommitted, greaterThan(1.5),
        reason: 'commit 首帧缩放应基本保持,由退场动画继续收拢');

    // 退场中途:持续单调收拢
    await tester.pump(const Duration(milliseconds: 100));
    final mid = controller.details!.totalScale!;
    expect(mid, lessThan(justCommitted));
    expect(mid, greaterThan(1.0));

    // 退场结束:精确 contain,Hero 落地帧无残余
    await tester.pumpAndSettle();
    expect(controller.details!.totalScale, closeTo(1.0, 0.001));
    expect(find.text('open'), findsOneWidget);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('预测返回 cancel:缩放弹回原状态', (tester) async {
    final controller = ImageGestureController();
    addTearDown(controller.dispose);
    await pumpViewer(tester, controller);

    zoomTo(controller, 2.5);
    await send('startBackGesture', gestureArgs(0.0));
    await tester.pump();
    await send('updateBackGestureProgress', gestureArgs(0.6));
    await tester.pump();
    expect(controller.details!.totalScale, lessThan(2.5));

    await send('cancelBackGesture');
    await tester.pumpAndSettle();
    // 路由动画弹回 1.0,lerp 末帧 = 原缩放
    expect(controller.details!.totalScale, closeTo(2.5, 0.01),
        reason: 'cancel 后应恢复用户原来的放大状态');
    expect(find.byType(_ZoomRelaxHarness), findsOneWidget);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));
}
