import 'dart:io';

import '../constants.dart';

class WebViewIsolation {
  WebViewIsolation._();

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
    if (!Platform.isAndroid && !Platform.isIOS) {
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
