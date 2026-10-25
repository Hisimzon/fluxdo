import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:m3e_ui/m3e_ui.dart';
import '../utils/frame_jank_monitor.dart';
import '../utils/link_launcher.dart';
import '../services/deep_link_service.dart';
import '../services/toast_service.dart';
import '../services/app_link_service.dart';
import '../services/network/cookie/cookie_store_observer.dart';
import '../services/network/cookie/webview_cookie_priming.dart';
import '../services/webview_settings.dart';
import '../services/network/discourse_dio.dart';
import '../services/windows_webview_environment_service.dart';
import '../widgets/common/app_link_confirm_dialog.dart';
import '../providers/web_bookmark_provider.dart';
import '../providers/web_history_provider.dart';
import '../providers/download_provider.dart';
import 'package:common_ui/common_ui.dart';
import '../l10n/s.dart';
import '../utils/dialog_utils.dart';
import '../utils/webview_isolation.dart';

/// 通用内置浏览器页面
class WebViewPage extends ConsumerStatefulWidget {
  final String url;
  final String? title;
  final String? injectCss;
  final bool isolated;
  final int? windowId;

  const WebViewPage({
    super.key,
    required this.url,
    this.title,
    this.injectCss,
    this.isolated = false,
    this.windowId,
  });

  /// 打开浏览器，url 为空字符串时显示空白页
  static Future<T?> open<T extends Object?>(
    BuildContext context,
    String url, {
    String? title,
    String? injectCss,
    bool? isolated,
    int? windowId,
  }) {
    final useIsolatedWebView = isolated ?? WebViewIsolation.shouldIsolate(url);
    return Navigator.push<T>(
      context,
      MaterialPageRoute(
        builder: (_) => WebViewPage(
          url: url,
          title: title,
          injectCss: injectCss,
          isolated: useIsolatedWebView,
          windowId: windowId,
        ),
      ),
    );
  }

  @override
  ConsumerState<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends ConsumerState<WebViewPage> {
  InAppWebViewController? _controller;
  bool _isLoading = true;
  String _currentUrl = '';
  String _currentTitle = '';
  double _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _historyStateSettled = false;
  int _navigationRevision = 0;

  /// 对话框期间用静态截图盖住 WebView，避免 BackdropFilter 对
  /// hybrid composition（Android）/HWND（Windows）实时回读造成卡顿。
  Uint8List? _webViewSnapshot;

  /// Windows 隔离 Environment 就绪标记。隔离页必须等它就绪再挂 WebView：
  /// 提前挂载会落到主/默认环境，主站 Cookie 直接泄露给第三方站点。
  bool _windowsIsolatedEnvReady = false;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.url;
    _currentTitle = widget.title ?? '';
    if (io.Platform.isWindows && widget.isolated) {
      WindowsWebViewEnvironmentService.instance
          .ensureIsolatedEnvironment()
          .whenComplete(() {
        if (mounted) {
          setState(() => _windowsIsolatedEnvReady = true);
        }
      });
    } else {
      _windowsIsolatedEnvReady = true;
    }
    // 可见 WebView(hybrid composition)在位期间会参与每帧合成,
    // 打点让诊断时间轴能对齐"WebView 页在前台"与掉帧段
    FrameJankMonitor.logEvent('WEBVIEW', 'WebViewPage mount');
  }

  @override
  void dispose() {
    FrameJankMonitor.logEvent('WEBVIEW', 'WebViewPage dispose');
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Windows: 隔离页挂独立 userDataFolder 的 Environment，
    // 主站页继续用主 Environment，Cookie 物理隔离。
    final windowsWebViewEnvironment = !io.Platform.isWindows
        ? null
        : (widget.isolated
              ? WindowsWebViewEnvironmentService.instance.isolatedEnvironment
              : WindowsWebViewEnvironmentService.instance.environment);
    // 隔离 Environment 尚未就绪(或创建失败)时绝不挂主环境降级运行。
    final deferIsolatedWebView =
        io.Platform.isWindows &&
        widget.isolated &&
        (!_windowsIsolatedEnvReady || windowsWebViewEnvironment == null);

    final theme = Theme.of(context);
    final isBookmarked = ref.watch(
      webBookmarkProvider.select(
        (list) => list.any((e) => e.url == _currentUrl),
      ),
    );

    return PopScope(
      // WebView 还有历史时，返回键先回退网页；到首层后交给路由，
      // 这样离开浏览器页面可以使用 Android 预测式返回动画。
      // 历史状态未稳定时保守拦截并实时查询，避免新页面刚开始导航、
      // _canGoBack 尚未回填的窗口里把整个 WebView 路由直接退出。
      canPop: _historyStateSettled && !_canGoBack,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _handleBackNavigation();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: GestureDetector(
            onTap: _showUrlInput,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  Icon(
                    Symbols.lock_rounded,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _currentTitle.isNotEmpty
                          ? _currentTitle
                          : (_currentUrl.isNotEmpty
                                ? _currentUrl
                                : context.l10n.webview_inputUrl),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color:
                            _currentTitle.isNotEmpty || _currentUrl.isNotEmpty
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          leading: Center(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Symbols.close_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          leadingWidth: 48,
          actions: [
            IconButton(
              icon: Icon(
                Symbols.chevron_left_rounded,
                color: _canGoBack ? null : theme.disabledColor,
              ),
              onPressed: _canGoBack ? () => _controller?.goBack() : null,
              tooltip: context.l10n.webview_goBack,
            ),
            IconButton(
              icon: Icon(
                Symbols.chevron_right_rounded,
                color: _canGoForward ? null : theme.disabledColor,
              ),
              onPressed: _canGoForward ? () => _controller?.goForward() : null,
              tooltip: context.l10n.webview_goForward,
            ),
            IconButton(
              icon: const Icon(Symbols.refresh_rounded),
              onPressed: () => _controller?.reload(),
              tooltip: context.l10n.common_refresh,
            ),
            SwipeDismissiblePopupMenuButton<String>(
              onSelected: _handleMenuAction,
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'toggle_bookmark',
                  child: Row(
                    children: [
                      Icon(Symbols.star_rounded, fill: isBookmarked ? 1 : 0,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        isBookmarked
                            ? context.l10n.webview_removeBookmark
                            : context.l10n.webview_addBookmark,
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'copy_url',
                  child: Row(
                    children: [
                      const Icon(Symbols.content_copy_rounded),
                      const SizedBox(width: 8),
                      Text(context.l10n.common_copyLink),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'open_external',
                  child: Row(
                    children: [
                      const Icon(Symbols.open_in_browser_rounded),
                      const SizedBox(width: 8),
                      Text(context.l10n.webview_openExternal),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        body: deferIsolatedWebView
            ? Center(
                // 隔离 Environment 未就绪：绝不降级挂主环境，主站 Cookie
                // 不能泄露给第三方站点。
                child: CircularProgressIndicator(
                  color: theme.colorScheme.primary,
                ),
              )
            : Column(
              children: [
                if (_isLoading)
                  M3eLinearProgress(
                    value: _progress,
                    trackColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Offstage(
                        offstage: _webViewSnapshot != null,
                        child: WebViewSettings.wrapWithScrollFix(
                      InAppWebView(
                            webViewEnvironment: windowsWebViewEnvironment,
                            windowId: widget.windowId,
                            initialSettings: widget.isolated
                                ? (WebViewSettings.visible
                                    ..useShouldOverrideUrlLoading = true
                                    ..supportMultipleWindows = true
                                    ..javaScriptCanOpenWindowsAutomatically = true
                                    ..incognito = true
                                    ..sharedCookiesEnabled = false
                                    ..thirdPartyCookiesEnabled = false
                                    ..cacheEnabled = false)
                                : (WebViewSettings.visible
                                    ..useShouldOverrideUrlLoading = true
                                    ..supportMultipleWindows = true
                                    ..javaScriptCanOpenWindowsAutomatically = true),
                            initialUserScripts:
                                WebViewSettings.compatPolyfillScripts,
                            shouldOverrideUrlLoading:
                                _shouldOverrideUrlLoading,
                            onCreateWindow: (controller, action) async {
                              return _handleCreatedWindow(action);
                            },
                            onCloseWindow: (_) {
                              if (!mounted) return;
                              final route = ModalRoute.of(context);
                              if (route?.isCurrent == true) {
                                Navigator.of(context).pop();
                              }
                            },
                            onReceivedServerTrustAuthRequest: (_, challenge) =>
                                WebViewSettings.handleServerTrustAuthRequest(
                                  challenge,
                                ),
                            onWebViewCreated: (controller) async {
                              _controller = controller;
                              // 老 WKWebView 的 JS 运行时错误回传到 LogWriter。
                              WebViewSettings.registerJsErrorReporter(controller);
                              if (widget.windowId == null &&
                                  widget.url.isNotEmpty) {
                                if (!widget.isolated) {
                                  // v0.4.0: 取代 RawSetCookieQueue.flush
                                  await WebViewCookiePriming.instance
                                      .prime(widget.url);
                                }
                                await controller.loadUrl(
                                  urlRequest:
                                      URLRequest(url: WebUri(widget.url)),
                                );
                              }
                              // Android: 启用 WebAuthn/PassKey 支持
                              if (io.Platform.isAndroid) {
                                WidgetsBinding.instance
                                    .addPostFrameCallback((_) {
                                  const MethodChannel('com.fluxdo/webauthn')
                                      .invokeMethod('enableWebAuthentication');
                                });
                              }
                            },
                            onLoadStart: (controller, url) {
                              setState(() {
                                _navigationRevision += 1;
                                _historyStateSettled = false;
                                _isLoading = true;
                                _currentUrl = url?.toString() ?? '';
                              });
                            },
                            onProgressChanged: (controller, progress) {
                              setState(() => _progress = progress / 100);
                            },
                            onLoadStop: (controller, url) async {
                              final revision = _navigationRevision;
                              setState(() => _isLoading = false);
                              if (!widget.isolated) {
                                // 触发 cookie observer sweep (Android 主要触发点;
                                // Apple 平台 native observer 已有覆盖, 此处与 debounce
                                // 合并不会重复 sweep)
                                CookieStoreObserver.instance
                                    .notifyExternalChange();
                              }
                              await WebViewSettings.injectScrollFix(controller);
                              final title = await controller.getTitle();
                              final canGoBack = await controller.canGoBack();
                              final canGoForward =
                                  await controller.canGoForward();
                              if (!mounted || revision != _navigationRevision) {
                                return;
                              }
                              final urlString = url?.toString();
                              setState(() {
                                _currentUrl = urlString ?? '';
                                _canGoBack = canGoBack;
                                _canGoForward = canGoForward;
                                _historyStateSettled = true;
                                if (title != null && title.isNotEmpty) {
                                  _currentTitle = title;
                                }
                              });
                              if (widget.injectCss != null) {
                                await controller.injectCSSCode(
                                  source: widget.injectCss!,
                                );
                              }
                              // 记录浏览历史
                              if (urlString != null && urlString.isNotEmpty) {
                                ref
                                    .read(webHistoryProvider.notifier)
                                    .record(urlString, _currentTitle);
                              }
                            },
                            onUpdateVisitedHistory:
                                (controller, url, isReload) async {
                                  final revision = _navigationRevision;
                                  final canGoBack =
                                      await controller.canGoBack();
                                  final canGoForward =
                                      await controller.canGoForward();
                                  if (!mounted ||
                                      revision != _navigationRevision) {
                                    return;
                                  }
                                  final urlString = url?.toString();
                                  setState(() {
                                    _currentUrl = urlString ?? '';
                                    _canGoBack = canGoBack;
                                    _canGoForward = canGoForward;
                                    _historyStateSettled = true;
                                  });
                                },
                            onTitleChanged: (controller, title) {
                              if (title != null && title.isNotEmpty) {
                                setState(() => _currentTitle = title);
                              }
                            },
                            onDownloadStarting: (controller, request) {
                              final url = request.url.toString();
                              ref
                                  .read(downloadProvider.notifier)
                                  .startDownload(
                                    url: url,
                                    suggestedFilename:
                                        request.suggestedFilename,
                                    mimeType: request.mimeType,
                                    contentLength: request.contentLength,
                                  );
                              return null;
                            },
                          ),
                          getController: () => _controller,
                        ),
                      ),
                      if (_webViewSnapshot != null)
                        Positioned.fill(
                          child: RepaintBoundary(
                            child: Image.memory(
                              _webViewSnapshot!,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
        ),
      ),
    );
  }

  /// 允许 WebView 内部加载的 scheme
  static const _allowedSchemes = {'http', 'https', 'about', 'data', 'blob'};

  /// 拦截 URL 加载：对非 HTTP(S) 的应用链接弹出确认对话框
  Future<NavigationActionPolicy> _shouldOverrideUrlLoading(
    InAppWebViewController controller,
    NavigationAction navigationAction,
  ) async {
    final url = navigationAction.request.url;
    if (url == null) return NavigationActionPolicy.ALLOW;

    final scheme = url.scheme.toLowerCase();

    if (scheme == 'http' || scheme == 'https') {
      final urlString = url.toString();
      final targetIsolated = WebViewIsolation.shouldIsolate(urlString);
      if (_isConnectAuthorizationUrl(url)) {
        await _openConfirmedConnectAuthorization(urlString);
        return NavigationActionPolicy.CANCEL;
      }
      if (mounted && targetIsolated != widget.isolated) {
        await WebViewPage.open(context, urlString);
      }
      return targetIsolated == widget.isolated
          ? NavigationActionPolicy.ALLOW
          : NavigationActionPolicy.CANCEL;
    }

    if (_allowedSchemes.contains(scheme)) {
      return NavigationActionPolicy.ALLOW;
    }

    // javascript: 静默阻止
    if (scheme == 'javascript') {
      return NavigationActionPolicy.CANCEL;
    }

    // 应用自有 scheme 直接交给深链服务，避免授权回调被当成外部应用
    // 链接弹出确认框，或在 WebView 内导航失败。
    if (scheme == 'fluxdo' || scheme == 'discourse') {
      DeepLinkService.instance.handleUri(url);
      return NavigationActionPolicy.CANCEL;
    }

    // 其他 scheme（应用链接）：解析目标应用并弹出确认对话框
    final urlString = url.toString();
    if (!mounted) return NavigationActionPolicy.CANCEL;

    // 通过原生代码解析目标应用信息
    final appInfo = await AppLinkService.resolveAppLink(urlString);

    if (!mounted) return NavigationActionPolicy.CANCEL;

    final confirmed = await showAppLinkConfirmDialog(
      context,
      urlString,
      appName: appInfo.appName,
      appIcon: appInfo.appIcon,
    );

    if (confirmed == true) {
      final success = await AppLinkService.launchAppLink(urlString);
      if (!success && mounted) {
        ToastService.showError(S.current.webview_noAppForLink);
      }
    }

    // 无论用户选择如何，都不让 WebView 加载此 URL
    return NavigationActionPolicy.CANCEL;
  }

  bool _isConnectAuthorizationUrl(Uri url) {
    final host = url.host.toLowerCase();
    return (host == 'connect.linux.do' ||
            host.endsWith('.connect.linux.do')) &&
        url.path.toLowerCase().startsWith('/oauth2/');
  }

  Future<bool> _confirmConnectAuthorizationIfNeeded(Uri url) async {
    if (!_isConnectAuthorizationUrl(url)) return true;
    return _confirmConnectAuthorization();
  }

  Future<bool> _openConfirmedConnectAuthorization(String urlString) async {
    final confirmed = await _confirmConnectAuthorization();
    if (!confirmed || !mounted) return false;
    final prepared = await _prepareConnectSession();
    if (!prepared || !mounted) return false;
    WebViewCookiePriming.instance.invalidateHost('connect.linux.do');
    await WebViewCookiePriming.instance.prime('https://connect.linux.do/');
    final sourceRoute = ModalRoute.of(context);
    await WebViewPage.open(context, urlString, isolated: false);
    if (mounted && sourceRoute != null && sourceRoute.isActive) {
      Navigator.of(context).removeRoute(sourceRoute);
    }
    return true;
  }

  Future<bool> _handleCreatedWindow(CreateWindowAction action) async {
    final url = action.request.url;
    if (url != null && _isConnectAuthorizationUrl(url)) {
      await _openConfirmedConnectAuthorization(url.toString());
      return true;
    }

    if (!mounted) return true;
    final urlString = url?.toString() ?? '';
    final inheritIsolation = _isOpaqueBlankUrl(urlString);
    await WebViewPage.open(
      context,
      // about:blank/#blocked 窗口不代表目标页面本身，只作为 windowId 宿主
      // 打开；后续真实导航会走新页面的 shouldOverrideUrlLoading，
      // 再由隔离边界与 connect OAuth 摆渡逻辑接管。
      inheritIsolation ? '' : urlString,
      isolated: inheritIsolation ? widget.isolated : null,
      windowId: action.windowId,
    );
    return true;
  }

  /// 空白/不可见目标的新窗口：包括空 URL、about:blank，以及 Chromium
  /// 在 opener 不可见目标时给出的 about:blank#blocked。
  /// 一些站点的 OAuth 登录链路正是先开这种窗口再导航到真实授权页。
  static bool _isOpaqueBlankUrl(String urlString) {
    if (urlString.isEmpty) return true;
    final uri = Uri.tryParse(urlString);
    if (uri == null) return false;
    if (uri.scheme != 'about') return false;
    return uri.path.isEmpty || uri.path == 'blank';
  }

  Future<bool> _confirmConnectAuthorization() async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.webview_thirdPartyAuthTitle),
        content: Text(context.l10n.webview_thirdPartyAuthMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.common_deny),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.common_allow),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<bool> _prepareConnectSession() async {
    try {
      final dio = DiscourseDio.create();
      final response = await dio.get(
        'https://connect.linux.do/',
        options: Options(
          validateStatus: (status) => status != null && status < 500,
          extra: {'skipCsrf': true, 'showErrorToast': false},
        ),
      );
      if (response.statusCode != 200) {
        ToastService.showError(S.current.common_loadFailedRetry);
        return false;
      }
      if (_isConnectLoginResponse(response.data.toString())) {
        ToastService.showError(S.current.common_pleaseLogin);
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('[WebView] Connect session bootstrap failed: $e');
      ToastService.showError(S.current.common_loadFailedRetry);
      return false;
    }
  }

  bool _isConnectLoginResponse(String html) {
    final document = html_parser.parse(html);
    final title =
        document.querySelector('title')?.text.trim().toLowerCase() ?? '';
    if (RegExp(r'login|log in|sign in|登录|登入|登錄|登陸').hasMatch(title)) {
      return true;
    }

    if (document.querySelector(
          'a[href*="/login"], form[action*="/login"], a[href*="/session"], form[action*="/session"]',
        ) !=
        null) {
      return true;
    }

    final buttonTexts = document
        .querySelectorAll('button, a')
        .map((element) => element.text.trim().toLowerCase())
        .where((text) => text.isNotEmpty);
    return buttonTexts.any(
      (text) => RegExp(r'^(log ?in|sign ?in|登录|登入|登錄|登陸)$').hasMatch(text),
    );
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'toggle_bookmark':
        _toggleBookmark();
        break;
      case 'copy_url':
        _copyUrl();
        break;
      case 'open_external':
        _openInExternalBrowser();
        break;
    }
  }

  /// 弹出 URL 输入对话框。
  ///
  /// 为避免 BackdropFilter 对实时 WebView 做高斯模糊导致的掉帧，
  /// 先截图盖在 WebView 之上，让对话框模糊的是静态图像。
  /// 截图覆盖后 WebView 也不再持有 InputConnection，键盘可立即弹出。
  Future<void> _showUrlInput() async {
    final snapshot = await _controller?.takeScreenshot();
    if (!mounted) return;
    if (snapshot != null) {
      setState(() => _webViewSnapshot = snapshot);
    }

    final textController = TextEditingController(text: _currentUrl);
    final focusNode = FocusNode();
    try {
      await showAppDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(S.current.webview_inputUrl),
          content: TextField(
            controller: textController,
            focusNode: focusNode,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              hintText: 'https://',
              suffixIcon: IconButton(
                icon: const Icon(Symbols.clear_rounded, size: 18),
                onPressed: () => textController.clear(),
              ),
            ),
            onSubmitted: (value) {
              Navigator.pop(ctx);
              _navigateToUrl(value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(S.current.common_cancel),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _navigateToUrl(textController.text);
              },
              child: Text(S.current.webview_go),
            ),
          ],
        ),
      );
    } finally {
      focusNode.dispose();
      textController.dispose();
      if (mounted && _webViewSnapshot != null) {
        setState(() => _webViewSnapshot = null);
      }
    }
  }

  Future<void> _navigateToUrl(String input) async {
    var url = input.trim();
    if (url.isEmpty) return;
    // 自动补全 scheme
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    final uri = Uri.tryParse(url);
    if (uri != null &&
        !await _confirmConnectAuthorizationIfNeeded(uri)) {
      return;
    }
    if (WebViewIsolation.shouldIsolate(url) != widget.isolated) {
      if (mounted) {
        await WebViewPage.open(context, url);
      }
      return;
    }
    _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  void _toggleBookmark() {
    if (_currentUrl.isEmpty) return;
    final added = ref
        .read(webBookmarkProvider.notifier)
        .toggle(_currentUrl, _currentTitle, isolated: widget.isolated);
    ToastService.showSuccess(
      added
          ? S.current.webview_bookmarkAdded
          : S.current.webview_bookmarkRemoved,
    );
  }

  Future<void> _handleBackNavigation() async {
    final controller = _controller;
    if (controller == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final canGoBack = await controller.canGoBack();
    if (canGoBack) {
      await controller.goBack();
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _copyUrl() async {
    if (_currentUrl.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: _currentUrl));
      if (mounted) {
        ToastService.showSuccess(S.current.common_linkCopied);
      }
    }
  }

  Future<void> _openInExternalBrowser() async {
    if (_currentUrl.isEmpty) return;

    try {
      final success = await launchInExternalBrowser(_currentUrl);
      if (!success && mounted) {
        ToastService.showError(S.current.webview_cannotOpenBrowser);
      }
    } catch (e) {
      if (mounted) {
        ToastService.showError(S.current.webview_openFailed(e.toString()));
      }
    }
  }
}
