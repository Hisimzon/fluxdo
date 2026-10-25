import 'dart:io';

import '../constants.dart';

class WebViewIsolation {
  WebViewIsolation._();

  /// Windows 隔离依赖独立 WebView2 Environment(独立 userDataFolder),
  /// 由 WindowsWebViewEnvironmentService.ensureIsolatedEnvironment 提供;
  /// Android/iOS 用 incognito + 禁共享 Cookie。
  static bool _isSupportedPlatform() =>
      Platform.isAndroid || Platform.isIOS || Platform.isWindows;

  static bool _isOfficialHost(Uri uri) {
    final baseUri = Uri.tryParse(AppConstants.baseUrl);
    final baseHost = baseUri?.host.toLowerCase();
    final host = uri.host.toLowerCase();
    if (baseHost == null || baseHost.isEmpty || host.isEmpty) {
      return false;
    }
    return host == baseHost || host.endsWith('.$baseHost');
  }

  static bool shouldIsolate(String url) {
    if (!_isSupportedPlatform()) {
      return false;
    }

    final uri = Uri.tryParse(url);
    if (uri == null) {
      return false;
    }

    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return false;
    }

    return !_isOfficialHost(uri);
  }
}
