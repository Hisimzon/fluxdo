import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../auth_session.dart';
import 'cookie_jar_service.dart';
import 'cookie_logger.dart';
import 'raw_cookie_writer.dart';
import 'session_cookie_sentinel.dart';

/// Prepares the shared WebView cookie store from the canonical application jar.
class WebViewCookiePriming {
  WebViewCookiePriming._();
  static final WebViewCookiePriming instance = WebViewCookiePriming._();

  CookieJarService _jar = CookieJarService();
  RawCookieWriter _writer = RawCookieWriter.instance;
  SessionCookieSentinel _sentinel = SessionCookieSentinel.instance;
  AuthSession _auth = AuthSession();

  final Map<String, Future<void>> _pending = {};
  final Map<String, int> _hostEpochs = {};
  final Map<String, int> _primedHosts = {};

  bool get isPrimed => _primedHosts.values.contains(_auth.generation);

  @visibleForTesting
  void replaceDependenciesForTest({
    CookieJarService? jar,
    RawCookieWriter? writer,
    SessionCookieSentinel? sentinel,
    AuthSession? auth,
  }) {
    if (jar != null) _jar = jar;
    if (writer != null) _writer = writer;
    if (sentinel != null) _sentinel = sentinel;
    if (auth != null) _auth = auth;
  }

  /// Concurrent requests for pages on the same origin share one priming pass.
  /// A ready host is still checked on each call so lost WebView cookies recover.
  Future<void> prime(String url) async {
    final uri = Uri.parse(url);
    if (!uri.hasAuthority || uri.host.isEmpty) {
      throw WebViewPrimingException(url, 'invalid URL');
    }
    final host = uri.host.toLowerCase();
    final origin = uri.origin;
    final existing = _pending[origin];
    if (existing != null) return existing;

    final epoch = _hostEpochs.putIfAbsent(host, () => 0);
    final generation = _auth.generation;
    late final Future<void> pending;
    pending = _prime(url, uri, host, epoch, generation).whenComplete(() {
      if (identical(_pending[origin], pending)) _pending.remove(origin);
    });
    _pending[origin] = pending;
    return pending;
  }

  Future<void> _prime(
    String url,
    Uri uri,
    String host,
    int epoch,
    int generation,
  ) async {
    final watch = Stopwatch()..start();
    CookieLogger.priming(event: 'invoked', url: url, isPrimed: false);
    var injected = 0;
    try {
      if (!_jar.isInitialized) await _jar.initialize();
      _checkSession(host, epoch, generation, url);

      // 每次同步前重新读取 jar，避免登录态变化后写回旧快照。
      final cookies = await _jar.loadCanonicalCookiesForRequest(uri);
      final expected = cookies
          .where(
            (cookie) =>
                CookieJarService.criticalCookieNames.contains(cookie.name) &&
                cookie.value.isNotEmpty &&
                !cookie.isExpired,
          )
          .toList(growable: false);
      final names = expected.map((cookie) => cookie.name).toSet();
      for (final name in names) {
        _checkSession(host, epoch, generation, url);
        final before = await _writer.getAllCookieInfos(url);
        _checkSession(host, epoch, generation, url);
        final canonicalForName = expected
            .where((cookie) => cookie.name == name)
            .toList(growable: false);
        if (!SessionCookieSentinel.matchesSnapshot(
          url,
          before.where((cookie) => cookie.name == name).toList(),
          canonicalForName,
        )) {
          final storedForName = before.where((cookie) => cookie.name == name);
          // clearance 可能先在 WebView 内轮换；保留浏览器新值，只在空 store 时补灌。
          if (name == 'cf_clearance' &&
              storedForName.any((cookie) => _appliesToRequest(uri, cookie.path))) {
            continue;
          }
          final latest = await _jar.loadCanonicalCookiesForRequest(uri);
          _checkSession(host, epoch, generation, url);
          final latestForName = latest
              .where(
                (cookie) =>
                    cookie.name == name &&
                    cookie.value.isNotEmpty &&
                    !cookie.isExpired,
              )
              .toList(growable: false);
          if (latestForName.isEmpty) continue;
          if (name == 'cf_clearance') {
            for (final cookie in latestForName) {
              _checkSession(host, epoch, generation, url);
              if (!await _writer.setRawCookie(
                url,
                cookie.toSetCookieHeader(),
                writeSharedStorage: false,
              )) {
                throw WebViewPrimingException(
                  url,
                  'native write failed for $name',
                );
              }
              injected++;
            }
          } else {
            final result = await _sentinel.syncFromJar(url, name);
            _checkSession(host, epoch, generation, url);
            if (result.status == SweepStatus.failed ||
                result.status == SweepStatus.cancelled) {
              throw WebViewPrimingException(
                url,
                'sentinel sync failed for $name (${result.status.name})',
              );
            }
            injected += result.status == SweepStatus.swept ? 1 : 0;
          }
        }
      }

      _checkSession(host, epoch, generation, url);
      // 用最新 jar 快照校验，避免初始读取后发生的轮换被遗漏。
      final latest = await _jar.loadCanonicalCookiesForRequest(uri);
      final verifyNames = latest
          .where(
            (cookie) =>
                CookieJarService.criticalCookieNames.contains(cookie.name) &&
                cookie.value.isNotEmpty &&
                !cookie.isExpired,
          )
          .map((cookie) => cookie.name)
          .toSet();
      final stored = await _writer.getAllCookieInfos(url);
      _checkSession(host, epoch, generation, url);
      for (final name in verifyNames) {
        final canonical = latest
            .where((cookie) => cookie.name == name)
            .toList(growable: false);
        final observed = stored.where((cookie) => cookie.name == name).toList();
        if (name == 'cf_clearance' &&
            observed.any((cookie) => _appliesToRequest(uri, cookie.path)) &&
            !SessionCookieSentinel.matchesSnapshot(url, observed, canonical)) {
          continue;
        }
        if (!SessionCookieSentinel.matchesSnapshot(
          url,
          observed,
          canonical,
        )) {
          throw WebViewPrimingException(url, 'verification failed for $name');
        }
      }

      _primedHosts[host] = generation;
      CookieLogger.priming(
        event: 'completed',
        url: url,
        isPrimed: true,
        cookiesInjected: injected,
        durationMs: watch.elapsedMilliseconds,
      );
    } catch (error) {
      _primedHosts.remove(host);
      CookieLogger.priming(
        event: 'failed',
        url: url,
        isPrimed: false,
        cookiesInjected: injected,
        durationMs: watch.elapsedMilliseconds,
        reason: error.toString(),
      );
      if (error is WebViewPrimingException) rethrow;
      debugPrint('[Cookie:Priming] failed @ $url: $error');
      throw WebViewPrimingException(url, error.toString(), error);
    }
  }

  void _checkSession(String host, int epoch, int generation, String url) {
    if ((_hostEpochs[host] ?? 0) != epoch || !_auth.isValid(generation)) {
      throw WebViewPrimingException(url, 'session changed during priming');
    }
  }

  static bool _appliesToRequest(Uri uri, String? cookiePath) {
    if (cookiePath == null) return true;
    final requestPath = uri.path.isEmpty ? '/' : uri.path;
    return requestPath == cookiePath ||
        (requestPath.startsWith(cookiePath) &&
            (cookiePath.endsWith('/') ||
                requestPath.substring(cookiePath.length).startsWith('/')));
  }

  void invalidate() {
    for (final host in {..._hostEpochs.keys, ..._primedHosts.keys}) {
      _hostEpochs[host] = (_hostEpochs[host] ?? 0) + 1;
    }
    _primedHosts.clear();
  }

  void invalidateHost(String host) {
    final normalized = host.toLowerCase();
    _hostEpochs[normalized] = (_hostEpochs[normalized] ?? 0) + 1;
    _primedHosts.remove(normalized);
  }

  Future<void> awaitReady() async {
    await Future.wait(_pending.values.toList(growable: false));
  }

  @visibleForTesting
  void resetForTest() {
    invalidate();
    _pending.clear();
    _hostEpochs.clear();
    _primedHosts.clear();
  }
}

class WebViewPrimingException implements Exception {
  WebViewPrimingException(this.url, this.message, [this.cause]);

  final String url;
  final String message;
  final Object? cause;

  @override
  String toString() =>
      'WebViewPrimingException($url): $message'
      '${cause == null ? '' : ' ($cause)'}';
}
