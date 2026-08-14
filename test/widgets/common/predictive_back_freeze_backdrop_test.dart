import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/predictive_back_cupertino_transitions.dart';

/// 差异点 11:手势期「冻结」分支必须带铺底。
///
/// 手势期 flag 按 Navigator 存(Expando 键=navigator),同一 Navigator
/// 下所有 phase==idle 的路由都进冻结分支;直接 return child 剥掉了
/// Cupertino 转场的背景填充 → 预测预览缩小后框外/边缘无人铺底,
/// 露出 Navigator 底色纯黑(连划黑底的真实几何)。
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

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

  testWidgets('手势期下层路由冻结时带 surface 铺底(不露 Navigator 黑底)',
      (tester) async {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.blue);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: scheme,
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.android:
                  PredictiveBackCupertinoPageTransitionsBuilder(),
            },
          ),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('page B')),
                ),
              ),
              child: const Text('page A'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('page A'));
    await tester.pumpAndSettle();

    // 手势开始:B 认领(phase=start),A 是 idle → 进冻结分支
    await send('startBackGesture', gestureArgs(0.0));
    await tester.pump();
    await send('updateBackGestureProgress', gestureArgs(0.4));
    await tester.pump();

    // 冻结的下层路由必须有 surface 铺底
    final coloredBoxes = tester.widgetList<ColoredBox>(
      find.byType(ColoredBox, skipOffstage: false),
    );
    expect(
      coloredBoxes.any((box) => box.color == scheme.surface),
      isTrue,
      reason: '冻结分支须垫 surface,否则预览框外露 Navigator 纯黑',
    );

    await send('cancelBackGesture');
    await tester.pumpAndSettle();
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('透明路由(opaque:false)冻结时不铺底,保持其下页面可见',
      (tester) async {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.blue);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: scheme),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                PageRouteBuilder<void>(
                  opaque: false,
                  pageBuilder: (_, _, _) => const Scaffold(
                    backgroundColor: Colors.transparent,
                    body: Text('overlay'),
                  ),
                  transitionsBuilder:
                      (context, animation, secondaryAnimation, child) =>
                          buildPredictiveBackPageTransitions(
                            context,
                            animation,
                            secondaryAnimation,
                            child,
                            useSharedElementPreview: false,
                            fallbackBuilder: (_, animation, _, child) =>
                                FadeTransition(
                                  opacity: animation,
                                  child: child,
                                ),
                          ),
                ),
              ),
              child: const Text('base page'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('base page'));
    await tester.pumpAndSettle();

    await send('startBackGesture', gestureArgs(0.0));
    await tester.pump();
    await send('updateBackGestureProgress', gestureArgs(0.3));
    await tester.pump();

    // 透明路由自身不该被垫上不透明底(否则遮住底层页面)
    expect(find.text('base page'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await send('cancelBackGesture');
    await tester.pumpAndSettle();
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));
}
