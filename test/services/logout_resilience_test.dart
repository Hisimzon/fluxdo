import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';

/// 登出流程的健壮性契约。
///
/// 现象:用户点退出后永久停在「正在退出…」。成因是双重的——
/// 1. `logout()` 第六步 `PreloadedDataService.refresh()` 失败会 rethrow
///    (它刻意如此,好让启动路径走 WebView 降级链),于是整个 logout 抛出;
/// 2. 调用方 `await logout()` 没有 try/catch,`LoadingDialog.hide` 永不执行。
///
/// 登出的本质是"清掉本地凭证并广播状态",这两件事不能被任何网络/解析问题
/// 阻断。refresh 只是为下一个匿名会话预热,属于尽力而为。
void main() {
  test('预加载刷新失败会抛出 —— 这是 logout 必须自己吞掉的异常来源', () async {
    // 未初始化 dio 的环境里 refresh 必然失败,正好用来固化"它会抛"这个事实。
    // 若哪天 refresh 改成静默失败,这个测试会红,提示 logout 里的兜底可以简化。
    await expectLater(
      PreloadedDataService().refresh(),
      throwsA(anything),
      reason: 'refresh 失败时抛出 → logout 必须 catch,否则调用方 loading 关不掉',
    );
  });
}
