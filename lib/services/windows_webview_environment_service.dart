import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 统一管理 Windows 平台的 WebView2 Environment。
///
/// 目标：
/// 1. 固定 userDataFolder，避免默认落在 exe 同级目录。
/// 2. 让 CookieManager / InAppWebView / HeadlessInAppWebView 使用同一环境。
/// 3. 支持通过 additionalBrowserArguments 设置代理。
///
/// WebView2 Environment 一旦创建，进程运行期间绝不销毁重建。插件原生层
/// 在仍有活跃 Controller 时 dispose Environment，可能永久堵死 Win32
/// 消息泵，表现为动画仍在播放但窗口无法点击、缩放或关闭。
class WindowsWebViewEnvironmentService {
  WindowsWebViewEnvironmentService._internal();

  static final WindowsWebViewEnvironmentService instance =
      WindowsWebViewEnvironmentService._internal();

  WebViewEnvironment? _environment;
  CookieManager? _cookieManager;
  Future<void>? _initializeFuture;
  String? _userDataFolder;
  String? _activeProxyUrl;
  String? _desiredProxyUrl;

  // 第三方站点隔离 Environment：独立 userDataFolder 实现 Cookie
  // 级隔离(WebView2 无 incognito，隔离只能靠独立用户数据目录)。
  // 与主 Environment 同样遵守「创建后绝不销毁重建」约束。
  WebViewEnvironment? _isolatedEnvironment;
  Future<void>? _isolatedInitializeFuture;
  String? _isolatedUserDataFolder;

  /// WebView2 Environment 的代理参数只能在创建时确定。运行中修改代理时，
  /// 由设置页持续提示用户重启，避免仅写日志后让用户误以为已经生效。
  final ValueNotifier<bool> proxyRestartRequiredNotifier = ValueNotifier(false);

  static const String _desiredProxyPrefKey =
      'windows_webview_desired_proxy_url';

  /// 隔离数据延迟清理标记：Environment 存活期间目录被 WebView2 进程
  /// 锁定无法整删，下次启动(创建隔离 Environment 前)再整目录清理。
  static const String _isolatedPendingClearPrefKey =
      'windows_webview_isolated_pending_clear';

  /// 本次启动的代理决策(NetworkSettingsService 起完本地代理后调用
  /// [setProxy] 时完成)。本地代理端口每次启动可能不同(上次的端口被
  /// TIME_WAIT / 残留会话占用时会随机漂移),Environment 一旦创建又不能
  /// 重建,拿着上次的旧端口创建会让整个会话的 WebView 全部断网。
  final Completer<void> _proxyDecision = Completer<void>();

  /// 代理决策的最长等待。超时兜底用上次持久化的期望值,避免代理启动
  /// 失败时卡死 Environment 创建。
  ///
  /// 8s 曾经不够用:本次调用排在 main.dart 启动链路里 rhttp 初始化
  /// 之后,而 rhttp 自己就留了最多 5s 超时预算,后面还有好几个服务
  /// 初始化——真机复现 8s 内等不到本次会话的真实代理端口,回退用了
  /// 上次持久化的旧端口(端口早已随 TIME_WAIT 漂移到别处),导致
  /// WebView2 在这次会话里全程连着一个不存在的代理，验证怎么也过不去。
  /// 放宽到 15s，盖过 rhttp 5s 预算 + 本地代理实际启动耗时的合理上限。
  static const _proxyDecisionTimeout = Duration(seconds: 15);

  bool get _isSupported => !kIsWeb && Platform.isWindows;

  WebViewEnvironment? get environment => _environment;

  /// 隔离 Environment。null 表示尚未创建或创建失败(此时调用方
  /// 不应已在渲染隔离 WebView)。
  WebViewEnvironment? get isolatedEnvironment => _isolatedEnvironment;

  String? get userDataFolder => _userDataFolder;
  String? get activeProxyUrl => _activeProxyUrl;
  String? get desiredProxyUrl => _desiredProxyUrl;
  bool get proxyRestartRequired => _activeProxyUrl != _desiredProxyUrl;
  int? get activeLocalProxyPort => parseLocalProxyPort(_activeProxyUrl);

  @visibleForTesting
  static int? parseLocalProxyPort(String? proxyUrl) {
    final uri = proxyUrl == null ? null : Uri.tryParse(proxyUrl);
    if (uri == null || uri.scheme != 'http' || !uri.hasPort) return null;
    final host = uri.host.toLowerCase();
    if (host != '127.0.0.1' && host != 'localhost' && host != '::1') {
      return null;
    }
    return uri.port;
  }

  static bool shouldRetainLocalProxy({
    required bool clearApplied,
    required int? activeEnvironmentPort,
    required int? runningProxyPort,
  }) {
    return !clearApplied &&
        activeEnvironmentPort != null &&
        activeEnvironmentPort == runningProxyPort;
  }

  void _syncProxyRestartRequired() {
    final value = proxyRestartRequired;
    if (proxyRestartRequiredNotifier.value != value) {
      proxyRestartRequiredNotifier.value = value;
    }
  }

  CookieManager get cookieManager {
    if (_isSupported && _environment != null) {
      return _cookieManager ??= CookieManager.instance(
        webViewEnvironment: _environment,
      );
    }
    return CookieManager.instance();
  }

  Future<void> initialize() {
    if (!_isSupported || _environment != null) {
      return Future.value();
    }
    return _initializeFuture ??= _createEnvironment();
  }

  /// 懒创建隔离 Environment。首次打开第三方站点时调用。
  ///
  /// 先等待主 Environment 就绪，以复用其代理决策；代理参数与主环境
  /// 保持一致，仅 userDataFolder 不同。
  Future<void> ensureIsolatedEnvironment() {
    if (!_isSupported || _isolatedEnvironment != null) {
      return Future.value();
    }
    return _isolatedInitializeFuture ??= _createIsolatedEnvironment();
  }

  /// 登记期望代理。Environment 已创建时不在运行期重建，变更将在下次
  /// 启动时生效。返回 true 表示当前 Environment 已经使用该代理。
  Future<bool> setProxy(String? proxyUrl) async {
    if (!_isSupported) return true;
    _desiredProxyUrl = proxyUrl;
    final prefs = await SharedPreferences.getInstance();
    if (proxyUrl == null) {
      await prefs.remove(_desiredProxyPrefKey);
    } else {
      await prefs.setString(_desiredProxyPrefKey, proxyUrl);
    }

    // 放行等待中的 Environment 创建(见 _proxyDecision 注释)。
    if (!_proxyDecision.isCompleted) {
      _proxyDecision.complete();
    }

    // 尚未开始创建时，可以直接让首次 Environment 使用最新期望值。
    if (_environment == null && _initializeFuture == null) {
      await initialize();
    } else if (_initializeFuture != null) {
      // 创建可能正在等待本次决策,等它完成再判断是否已生效。
      await _initializeFuture;
    }
    final applied = _environment != null && _activeProxyUrl == proxyUrl;
    _syncProxyRestartRequired();
    if (!applied) {
      debugPrint(
        '[WebViewEnv] proxy change deferred until restart: '
        'active=${_activeProxyUrl ?? 'direct'}, '
        'desired=${proxyUrl ?? 'direct'}',
      );
    }
    return applied;
  }

  Future<void> _createEnvironment() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _desiredProxyUrl ??= prefs.getString(_desiredProxyPrefKey);

      // 上次会话在用本地代理 → 本次大概率也会起代理,但端口可能变化。
      // 等 setProxy 带来本次的实际地址再创建;超时则退回持久化的旧值。
      if (_desiredProxyUrl != null && !_proxyDecision.isCompleted) {
        try {
          await _proxyDecision.future.timeout(_proxyDecisionTimeout);
        } on TimeoutException {
          debugPrint(
            '[WebViewEnv] 等待代理决策超时，使用上次持久化的代理地址: '
            '$_desiredProxyUrl',
          );
        }
      }
      if (_userDataFolder == null) {
        final supportDirectory = await getApplicationSupportDirectory();
        _userDataFolder = path.join(supportDirectory.path, 'webview2');
        final userDataDirectory = Directory(_userDataFolder!);
        if (!await userDataDirectory.exists()) {
          await userDataDirectory.create(recursive: true);
        }
      }

      // 动态 SVG 等帖子内容会频繁创建/销毁 CompositionController。WebView2
      // 默认会为这些 data 页面保留大量独立 renderer，实机曾累计到 20+
      // 个存活进程并拖慢系统消息泵。限制的是 renderer 数量，不影响浏览器、
      // GPU、网络服务等基础子进程；6 个也足够登录/CF 与帖子内容并行。
      final browserArguments = <String>['--renderer-process-limit=6'];
      if (_desiredProxyUrl != null) {
        browserArguments.add('--proxy-server=$_desiredProxyUrl');
      }
      final additionalBrowserArguments = browserArguments.join(' ');

      _environment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          userDataFolder: _userDataFolder,
          additionalBrowserArguments: additionalBrowserArguments,
        ),
      );
      _activeProxyUrl = _desiredProxyUrl;
      _syncProxyRestartRequired();
      _cookieManager = CookieManager.instance(webViewEnvironment: _environment);

      debugPrint(
        '[WebViewEnv] Windows WebView2 environment initialized: '
        'userDataFolder=$_userDataFolder'
        '${_desiredProxyUrl != null ? ', proxy=$_activeProxyUrl' : ''}, '
        'rendererLimit=6',
      );
    } catch (e, stackTrace) {
      debugPrint('[WebViewEnv] Windows environment init failed: $e');
      debugPrintStack(
        label: '[WebViewEnv] initialize stack',
        stackTrace: stackTrace,
      );
      _environment = null;
      _cookieManager = null;
      _activeProxyUrl = null;
      _syncProxyRestartRequired();
      _initializeFuture = null;
    }
  }

  Future<void> _createIsolatedEnvironment() async {
    try {
      // 主环境先行：它已等待过代理决策，_desiredProxyUrl 已是本次会话
      // 的最终值(或持久化回退值)，隔离环境直接复用。
      await initialize();

      // 上次会话标记的延迟清理：本会话隔离 Environment 尚未创建，目录
      // 无进程占用，整删后重建；失败(残留进程锁目录)则保留标记下次再试。
      await _purgeIsolatedDataIfPending();

      if (_isolatedUserDataFolder == null) {
        final userDataDirectory = await _resolveIsolatedDataFolder();
        _isolatedUserDataFolder = userDataDirectory.path;
        if (!await userDataDirectory.exists()) {
          await userDataDirectory.create(recursive: true);
        }
      }

      final browserArguments = <String>['--renderer-process-limit=6'];
      if (_desiredProxyUrl != null) {
        browserArguments.add('--proxy-server=$_desiredProxyUrl');
      }

      _isolatedEnvironment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          userDataFolder: _isolatedUserDataFolder,
          additionalBrowserArguments: browserArguments.join(' '),
        ),
      );

      debugPrint(
        '[WebViewEnv] isolated WebView2 environment initialized: '
        'userDataFolder=$_isolatedUserDataFolder'
        '${_desiredProxyUrl != null ? ', proxy=$_desiredProxyUrl' : ''}',
      );
    } catch (e, stackTrace) {
      debugPrint('[WebViewEnv] isolated environment init failed: $e');
      debugPrintStack(
        label: '[WebViewEnv] isolated initialize stack',
        stackTrace: stackTrace,
      );
      _isolatedEnvironment = null;
      _isolatedInitializeFuture = null;
    }
  }

  /// 隔离数据目录（即使 Environment 尚未创建也能定位，供统计/清理）。
  Future<Directory> _resolveIsolatedDataFolder() async {
    final supportDirectory = await getApplicationSupportDirectory();
    return Directory(
      path.join(supportDirectory.path, 'webview2-isolated'),
    );
  }

  /// 第三方站点隔离数据占用(字节)。目录不存在为 0，统计失败为 -1。
  Future<int> getIsolatedDataSize() async {
    if (!_isSupported) return -1;
    try {
      final dir = await _resolveIsolatedDataFolder();
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {
            // 被占用的临时文件忽略即可
          }
        }
      }
      return total;
    } catch (e) {
      debugPrint('[WebViewEnv] isolated data size calc failed: $e');
      return -1;
    }
  }

  /// 清除第三方站点隔离数据(Cookie + 缓存 + 站点存储)。
  ///
  /// 返回 true：目录已整删，立即生效；
  /// 返回 false：本会话隔离 Environment 已创建、目录被 WebView2 进程
  /// 锁定，已现场清 Cookie，磁盘文件标记下次启动自动整删
  /// (见 [_purgeIsolatedDataIfPending])。
  /// 均不影响主站 Environment 的任何数据。
  Future<bool> clearIsolatedData() async {
    if (!_isSupported) return true;
    try {
      final dir = await _resolveIsolatedDataFolder();
      if (!await dir.exists()) return true;
      if (_isolatedEnvironment == null) {
        // 尚无隔离 Environment：目录无进程占用，直接整删
        await dir.delete(recursive: true);
        debugPrint('[WebViewEnv] isolated data purged');
        return true;
      }
      // Environment 存活：Cookie 现场清(第三方站点立即登出)，
      // 被锁定的缓存/存储文件推迟到下次启动。
      try {
        final isolatedCookieManager = CookieManager.instance(
          webViewEnvironment: _isolatedEnvironment,
        );
        await isolatedCookieManager.deleteCookies();
      } catch (e) {
        debugPrint('[WebViewEnv] isolated cookies clear failed: $e');
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_isolatedPendingClearPrefKey, true);
      debugPrint('[WebViewEnv] isolated data clear deferred to next launch');
      return false;
    } catch (e) {
      debugPrint('[WebViewEnv] isolated data clear failed: $e');
      rethrow;
    }
  }

  /// 启动期延迟清理：Environment 创建前目录无锁，整删成功后清除标记。
  Future<void> _purgeIsolatedDataIfPending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_isolatedPendingClearPrefKey) ?? false) {
        final dir = await _resolveIsolatedDataFolder();
        if (await dir.exists()) {
          await dir.delete(recursive: true);
          debugPrint('[WebViewEnv] pending isolated data purged on startup');
        }
      }
      await prefs.setBool(_isolatedPendingClearPrefKey, false);
    } catch (e) {
      // 目录被残留进程锁定等：保留标记，下次启动再试。
      debugPrint('[WebViewEnv] pending isolated purge failed: $e');
    }
  }
}
