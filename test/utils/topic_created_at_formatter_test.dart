import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/topic_created_at_formatter.dart';

void main() {
  final now = DateTime(2026, 8, 13, 18);

  test('formats topic creation time by calendar range', () {
    expect(
      formatTopicCreatedAt(DateTime(2026, 8, 13, 12, 1), now: now),
      '12:01',
    );
    expect(
      formatTopicCreatedAt(DateTime(2026, 1, 15, 12, 1), now: now),
      '1月15日12:01',
    );
    expect(
      formatTopicCreatedAt(DateTime(2024, 1, 15, 12, 1), now: now),
      '2024年1月15日12:01',
    );
    expect(formatTopicCreatedAt(null, now: now), '');
  });
}
