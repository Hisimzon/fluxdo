import 'dart:io';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/app_cookie_manager.dart';
import 'package:fluxdo/services/network/interceptors/self_healing_interceptor.dart';

/// AppCookieManager 与 SelfHealingInterceptor 的注册顺序契约。
///
/// dio 5.11 的 onRequest/onResponse/onError 三相**全部按注册顺序 FIFO** 执行
/// (dio_mixin.dart 里三个 for 循环都正序遍历 interceptors)。
///
/// 服务端拒绝会话时常在 401 上带 `Set-Cookie: _t=; Max-Age=0`。
/// SelfHealing 判定"是否值得自愈"的依据是 jar 中 `_t` 是否仍有效,
/// 因此它必须在 AppCookieManager 把这条删除指令落库**之前**读到 jar 快照。
/// → SelfHealing 必须注册在 AppCookieManager 之前。
void main() {
  test('401 携带清除 _t 的 Set-Cookie 时，自愈仍看到有效 jar 快照并触发重试', () async {
    final env = _HealEnv();
    // 关键顺序:SelfHealing 在前，AppCookieManager 在后。
    final dio = env.buildDio(selfHealFirst: true);

    final response = await dio.get('/latest.json');

    expect(response.statusCode, 200);
    expect(env.adapter.fetchCount, greaterThanOrEqualTo(2));
    expect(env.tokenReadsWhileValid, greaterThan(0));
  });

  test('反向顺序会让自愈失效（回归护栏：证明顺序就是语义）', () async {
    final env = _HealEnv();
    // 错误顺序:AppCookieManager 先落库删除指令，SelfHealing 再查已无 _t。
    final dio = env.buildDio(selfHealFirst: false);

    await expectLater(dio.get('/latest.json'), throwsA(isA<DioException>()));

    // 只发了一次请求，自愈没有启动
    expect(env.adapter.fetchCount, 1);
  });
}

/// 测试脚手架:jar 快照读取口直连真实 CookieJar,使"删除指令是否已落库"
/// 能被自愈判定真实感知。
class _HealEnv {
  _HealEnv() : adapter = _Expiring401ThenOkAdapter() {
    realJar.saveFromResponse(_uri, [Cookie('_t', 'valid-token')..path = '/']);
  }

  static final _uri = Uri.parse('https://linux.do/latest.json');

  final CookieJar realJar = CookieJar();
  final _Expiring401ThenOkAdapter adapter;

  /// 自愈判定读到"仍有有效 _t"的次数。
  int tokenReadsWhileValid = 0;

  Future<CanonicalCookie?> _readSessionToken() async {
    final cookies = await realJar.loadForRequest(_uri);
    for (final cookie in cookies) {
      if (cookie.name == '_t' && cookie.value.isNotEmpty) {
        tokenReadsWhileValid++;
        return CanonicalCookie(name: cookie.name, value: cookie.value);
      }
    }
    return null;
  }

  Dio buildDio({required bool selfHealFirst}) {
    final dio = Dio(
      BaseOptions(
        baseUrl: 'https://linux.do',
        validateStatus: (status) => status != null && status < 400,
      ),
    )..httpClientAdapter = adapter;

    final selfHeal = SelfHealingInterceptor(dio: dio)
      ..replaceDependenciesForTest(readSessionToken: _readSessionToken);
    final cookieManager = AppCookieManager(realJar);

    if (selfHealFirst) {
      dio.interceptors.add(selfHeal);
      dio.interceptors.add(cookieManager);
    } else {
      dio.interceptors.add(cookieManager);
      dio.interceptors.add(selfHeal);
    }
    return dio;
  }
}

/// 首个请求返回 401 + 清除 _t 的 Set-Cookie；后续请求返回 200。
class _Expiring401ThenOkAdapter implements HttpClientAdapter {
  int fetchCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetchCount++;
    if (fetchCount == 1) {
      return ResponseBody.fromString(
        '{"error":"unauthorized"}',
        401,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
          HttpHeaders.setCookieHeader: [
            '_t=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
          ],
        },
      );
    }
    return ResponseBody.fromString(
      '{"ok":true}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
