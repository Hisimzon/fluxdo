import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/topic_summary_request.dart';

void main() {
  group('TopicSummaryRequest', () {
    test('默认请求允许服务端复用缓存摘要', () {
      const request = TopicSummaryRequest(42);

      expect(request.topicId, 42);
      expect(request.skipAgeCheck, isFalse);
      expect(request.generation, 0);
    });

    test('用户刷新会强制绕过年龄检查并创建新 key', () {
      const initial = TopicSummaryRequest(42);
      final regenerated = initial.nextRegeneration();

      expect(regenerated.topicId, 42);
      expect(regenerated.skipAgeCheck, isTrue);
      expect(regenerated.generation, 1);
      expect(regenerated, isNot(equals(initial)));
    });

    test('连续刷新每次都会创建不同的 Provider key', () {
      const initial = TopicSummaryRequest(42);
      final first = initial.nextRegeneration();
      final second = first.nextRegeneration();

      expect(second.skipAgeCheck, isTrue);
      expect(second.generation, 2);
      expect(second, isNot(equals(first)));
    });
  });
}
