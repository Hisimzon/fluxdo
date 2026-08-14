import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../flux_request_spec.dart';
import 'recovery_policy.dart';

/// 恢复层的**唯一重放引擎**。
///
/// 此前项目里有六个各自 `dio.fetch()` 重灌全链的重放入口(自愈、Cronet
/// 降级、限流重试、重定向、CF 验证 ×2),每个都要自己操心清 Cookie 头、
/// 打防环标记、绕过调度器——漏一个就是死循环。这里把重放收敛成一处:
///
/// - 策略只产出 [RecoveryDecision],不执行重放;
/// - 重放前置工作(清 Cookie 头、递增尝试计数)统一在 [_nextAttempt];
/// - 任何策略都绕不过 [AttemptBudget],防环由结构保证。
///
/// 以 Dio 拦截器形式接入:它必须是**错误链上最后一个**恢复者,前面的
/// 拦截器(CF 验证、自愈)迁入策略后即可逐个撤下(设计文档 M4/M5)。
class RecoveryCoordinator extends Interceptor {
  RecoveryCoordinator({
    required this.dio,
    required List<RecoveryPolicy> policies,
    AttemptBudget Function()? budgetFactory,
  }) : _policies = policies,
       _budgetFactory = budgetFactory ?? AttemptBudget.new;

  /// 用于重放的 Dio(通常是本拦截器所在的实例)。
  final Dio dio;

  final List<RecoveryPolicy> _policies;
  final AttemptBudget Function() _budgetFactory;

  /// 标记请求已由本协调器接管,防止重放请求再次进入恢复流程
  /// (重放走 dio.fetch 会重跑整条拦截器链)。
  static const String _managedKey = '_recoveryManaged';

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    // 已在恢复循环中的请求:直接透传,由外层循环处理
    if (err.requestOptions.extra[_managedKey] == true) {
      handler.next(err);
      return;
    }

    // 调用方声明不需要恢复(长轮询/后台 isolate/页面数据自己降级)
    if (err.requestOptions.spec.recoveryDisabled) {
      handler.next(err);
      return;
    }

    var outcome = AttemptOutcome.failure(error: err, attemptIndex: 0);
    final budget = _budgetFactory();

    while (true) {
      final policy = _firstMatch(outcome);
      if (policy == null) {
        handler.next(outcome.error!);
        return;
      }

      final decision = await policy.decide(outcome);

      switch (decision) {
        case RecoveryComplete():
          handler.next(outcome.error!);
          return;

        case RecoveryFail(:final error):
          handler.next(error);
          return;

        case RecoveryRetry(:final delay):
          if (!budget.tryConsume(policy.name)) {
            debugPrint(
              '[Recovery] 预算耗尽 policy=${policy.name} '
              'attempts=${budget.attemptsUsed}/${budget.maxAttempts} '
              '${outcome.error!.requestOptions.uri}',
            );
            handler.next(outcome.error!);
            return;
          }
          if (delay > Duration.zero) {
            await Future<void>.delayed(delay);
          }
          debugPrint(
            '[Recovery] 重放 policy=${policy.name} '
            'attempt=${budget.attemptsUsed}/${budget.maxAttempts} '
            '${outcome.error!.requestOptions.uri}',
          );
          final next = await _replay(outcome, budget.attemptsUsed - 1);
          if (next.isSuccess) {
            handler.resolve(next.response!);
            return;
          }
          outcome = next;
      }
    }
  }

  RecoveryPolicy? _firstMatch(AttemptOutcome outcome) {
    for (final policy in _policies) {
      if (policy.canHandle(outcome)) return policy;
    }
    return null;
  }

  /// 执行一次重放。所有重放前置工作集中在此,不由策略各自操心。
  Future<AttemptOutcome> _replay(
    AttemptOutcome previous,
    int attemptIndex,
  ) async {
    final options = _nextAttempt(previous.error!.requestOptions);
    try {
      final response = await dio.fetch<dynamic>(options);
      return AttemptOutcome.success(
        response: response,
        attemptIndex: attemptIndex,
      );
    } on DioException catch (e) {
      return AttemptOutcome.failure(error: e, attemptIndex: attemptIndex);
    }
  }

  /// 为下一次尝试重建请求选项。
  ///
  /// 关键点:清掉残留的 Cookie 头。重放走 dio.fetch 会重跑 AppCookieManager,
  /// 但若旧头还在,某些路径下会继续发送过期值(自愈/CF 重放都曾各自处理
  /// 这件事,现在只此一处)。
  RequestOptions _nextAttempt(RequestOptions previous) {
    final extra = Map<String, dynamic>.from(previous.extra)
      ..[_managedKey] = true;
    final headers = Map<String, dynamic>.from(previous.headers)
      ..remove('cookie')
      ..remove('Cookie');

    return previous.copyWith(headers: headers, extra: extra);
  }
}
