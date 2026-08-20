import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/content/discourse_html_content/builders/image_carousel_builder.dart';
import 'package:fluxdo/widgets/content/discourse_html_content/builders/image_grid_builder.dart';
import 'package:fluxdo/widgets/content/discourse_html_content/image_utils.dart';

/// 轮播源端 Hero 的飞行几何。
///
/// **症状**:从轮播点开大图再返回,尾帧图片铺满整条轮播槽位(且一度落点
/// 偏左),然后才直接变成小图。
///
/// **根因是结构而非算式**:原先是
/// `Hero > Image(fit: contain, width: infinity, height: carouselHeight)`,
/// Hero 的布局盒子 = 整条槽位,而画面只占其中一块。真机实测 768x300 的槽位
/// 里,500x500 的图只画 300x300(左右各留 234 空白)。Hero 飞行几何取布局
/// 盒子,于是尾帧铺满槽位,Hero 撤走后才由 Image 的 contain 缩成小图。
///
/// **修法:让 Hero 只包住画面**。用 AspectRatio 把盒子收到图片真实比例、
/// 居中放进槽位,于是 Hero 盒子 ≡ 画面,飞行两端天然对齐。
///
/// 此前三轮都在 createRectTween 上打补丁(拿算式去追结构),留档免得重走:
///  1. 「落点收成 contain 矩形」—— 算式与真机 paintedRect 逐位一致,但治标;
///  2. 「落点选中离屏 keepAlive 页拿到 NaN」—— 离屏页确实恒 NaN,但那会让
///     飞行体退化成固有尺寸乱摆,与症状不符;且实机确认第一张就会,不翻页;
///  3. 「用 exitFlightRect 覆盖 begin」—— **有害**。该字段判据是
///     totalScale > 1,而查看器对小图本身就放大适配(500x500 撑到 1212 宽),
///     故用户没放大它也非 null,实测 1212x1212 且上下溢出屏幕 191px,
///     拿它当起点整条路径歪掉,反而引入了落点偏移。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 挂一条轮播;槽位宽度由外层 SizedBox 决定
  Future<void> pumpCarousel(
    WidgetTester tester, {
    required double? imgW,
    required double? imgH,
    double slotWidth = 768,
  }) async {
    const src = 'https://example.com/a.png';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: slotWidth,
              child: Builder(
                builder: (context) => buildImageCarousel(
                  context: context,
                  theme: Theme.of(context),
                  images: [
                    GridImageData(
                      src: src,
                      fullSrc: src,
                      width: imgW,
                      height: imgH,
                    ),
                  ],
                  galleryInfo: GalleryInfo.fromImages(const [src]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Rect heroRect(WidgetTester tester) =>
      tester.getRect(find.byType(Hero).first);

  testWidgets('正方形图:Hero 盒子 = 画面(300x300 居中),而非整条槽位', (
    tester,
  ) async {
    // 与真机同参:500x500 的图 / 768 宽槽位 / 300 高
    await pumpCarousel(tester, imgW: 500, imgH: 500);

    final r = heroRect(tester);
    expect(r.width, closeTo(300, 0.5),
        reason: 'Hero 盒子宽仍是槽位宽 ⇒ 尾帧会铺满槽位');
    expect(r.height, closeTo(300, 0.5));
    // 居中于 768 宽的槽位:左右各留 (768-300)/2 = 234
    expect(r.width, lessThan(768 - 400),
        reason: '与槽位几乎同宽 = 结构没生效');
  });

  testWidgets('宽图:Hero 盒子按比例收拢(高度撑满槽位)', (tester) async {
    // 16:9 进 300 高的槽位 → 533.3 x 300
    await pumpCarousel(tester, imgW: 1600, imgH: 900);
    final r = heroRect(tester);
    expect(r.width, closeTo(533.3, 1.0));
    expect(r.height, closeTo(300, 0.5));
  });

  testWidgets('窄高图:Hero 盒子按比例收拢(宽度很窄)', (tester) async {
    // 9:16 进 300 高 → 168.75 x 300
    await pumpCarousel(tester, imgW: 900, imgH: 1600);
    final r = heroRect(tester);
    expect(r.width, closeTo(168.75, 1.0));
    expect(r.height, closeTo(300, 0.5));
  });

  testWidgets('缺原始宽高:退回旧结构(Hero 包整条槽位)', (tester) async {
    // 无宽高则无从得知比例,只能保持旧行为 —— 但不该崩
    await pumpCarousel(tester, imgW: null, imgH: null);
    final r = heroRect(tester);
    expect(r.width, closeTo(768, 1.0),
        reason: '退化分支应铺满槽位(旧结构),而不是收成 0 或异常尺寸');
    expect(r.height, closeTo(300, 0.5));
  });

  testWidgets('不再依赖 createRectTween(结构已保证两端对齐)', (tester) async {
    await pumpCarousel(tester, imgW: 500, imgH: 500);
    final hero = tester.widget<Hero>(find.byType(Hero).first);
    expect(
      hero.createRectTween,
      isNull,
      reason: '结构修法下不该再有落点修正 —— 若又加回来,说明在拿算式追结构',
    );
  });

  testWidgets('槽位变窄时 Hero 盒子跟着走(不写死尺寸)', (tester) async {
    await pumpCarousel(tester, imgW: 500, imgH: 500, slotWidth: 200);
    final r = heroRect(tester);
    // 槽位只有 200 宽,正方形图受宽度约束 → 200x200
    expect(r.width, closeTo(200, 1.0));
    expect(r.height, closeTo(200, 1.0));
  });
}
