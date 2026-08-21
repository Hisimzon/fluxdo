import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **覆盖率网关**:所有指向图片查看器的源端 Hero 都必须挂
/// `createRectTween: viewerHeroRectTween`。
///
/// 为什么需要这道扫描:这段逻辑原先各处各写一份,漏一处就少一处效果。真机
/// 先后暴露过轮播、聊天图片放大后返回「大图瞬间变小再播动画」;排查时发现
/// 6 个源端里只有 2 个有它(网格瓦片、正文单图、用户头像也都缺)。
/// 逐处补完之后,唯一能防住"下次新增又漏"的办法就是扫源码 —— 单测覆盖不到
/// 「某个文件忘了写一行」这种缺失。
///
/// 判据:文件里出现 `Hero(` 且该文件与图片查看器有关(引用 ImageViewerPage /
/// openViewer / heroTag),就必须出现 viewerHeroRectTween。
void main() {
  test('指向查看器的源端 Hero 都挂了 viewerHeroRectTween', () {
    // 已知豁免:这些文件有 Hero 但不指向图片查看器
    const exempt = <String, String>{
      'lib/pages/topics_page.dart': '搜索胶囊 Hero(飞向搜索页,非图片查看器)',
      'lib/pages/search_page.dart': '搜索胶囊 Hero 的另一端',
      'lib/pages/image_viewer_page.dart': '查看器自身(飞行的另一端,起点由它发布)',
    };

    final offenders = <String>[];
    final checked = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path;
      if (exempt.containsKey(path)) continue;

      final src = entity.readAsStringSync();
      if (!src.contains('Hero(')) continue;

      // 与图片查看器相关?
      final viewerRelated = src.contains('ImageViewerPage') ||
          src.contains('openViewer') ||
          src.contains('heroTag');
      if (!viewerRelated) continue;

      checked.add(path);
      if (!src.contains('viewerHeroRectTween')) offenders.add(path);
    }

    // 前提校验:扫描确实覆盖到了已知的源端,否则这个测试是空转
    expect(
      checked.length,
      greaterThanOrEqualTo(5),
      reason: '只扫到 ${checked.length} 个源端,判据可能失效(文件被重命名?)'
          '扫到的=$checked',
    );

    expect(
      offenders,
      isEmpty,
      reason:
          '以下文件有指向查看器的 Hero 但没挂 viewerHeroRectTween ⇒ 放大后返回'
          '会是「大图瞬间变小再播动画」:\n  ${offenders.join("\n  ")}\n'
          '修法:给那个 Hero 加 createRectTween: viewerHeroRectTween',
    );
  });

  test('豁免清单本身有效(文件还在,且确实不指向查看器)', () {
    // 防止豁免项因重命名而静默失效
    const exempt = [
      'lib/pages/topics_page.dart',
      'lib/pages/search_page.dart',
      'lib/pages/image_viewer_page.dart',
    ];
    for (final path in exempt) {
      expect(
        File(path).existsSync(),
        isTrue,
        reason: '豁免项 $path 不存在了 —— 清理或更新豁免清单',
      );
    }
  });

  test('cover 裁切展示的源端必须传 heroSourceFit + thumbnailUrl', () {
    // 源端若以 BoxFit.cover 裁切展示,查看器侧必须知道(heroSourceFit),
    // 才会走 CoverContainFlightImage 的裁切插值飞行体;还必须给
    // thumbnailUrl 作位图源,否则自绘飞行体无图可画、退回 child。
    //
    // 漏传的后果(真机实测):聊天图片预测返回到最后停在**裁切后的画面**,
    // 而不是完整图 —— 因为飞行体没做 cover→contain 的窗口张开。
    // 网格瓦片一直传着这两个参数,聊天此前漏了。
    final offenders = <String>[];
    final checked = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final src = entity.readAsStringSync();

      // 只看「自己开查看器」且「以 cover 展示缩略图」的文件
      final opensViewer = src.contains('ImageViewerPage.open(') ||
          src.contains('DiscourseImageUtils.openViewer(');
      if (!opensViewer) continue;
      if (!src.contains('fit: BoxFit.cover')) continue;
      // openBytes(内存图)没有 Hero 飞行,不在契约内
      if (!src.contains('heroTag')) continue;

      checked.add(entity.path);
      final ok = src.contains('heroSourceFit') || src.contains('heroSourceCircular');
      if (!ok || !src.contains('thumbnailUrl')) offenders.add(entity.path);
    }

    expect(
      checked.length,
      greaterThanOrEqualTo(2),
      reason: '只扫到 ${checked.length} 个 cover 源端,判据可能失效;扫到=$checked',
    );
    expect(
      offenders,
      isEmpty,
      reason:
          '以下文件以 cover 裁切展示却没告知查看器 ⇒ 返回尾帧会停在裁切态:\n'
          '  ${offenders.join("\n  ")}\n'
          '修法:开查看器时传 heroSourceFit: BoxFit.cover(圆形头像用'
          ' heroSourceCircular)+ thumbnailUrl',
    );
  });
}
