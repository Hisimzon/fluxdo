import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/message_bus_service.dart';

void main() {
  group('MessageBusService.waitForSubscription', () {
    const channel = '/discourse-ai/summaries/topic/42';
    late _MessageBusAdapter adapter;
    late Dio dio;
    late MessageBusService bus;

    setUp(() {
      adapter = _MessageBusAdapter();
      dio = Dio(BaseOptions(baseUrl: 'https://example.com'))
        ..httpClientAdapter = adapter;
      bus = MessageBusService.forTesting(dio: dio);
    });

    tearDown(() async {
      bus.dispose();
      dio.close(force: true);
      await Future<void>.delayed(Duration.zero);
    });

    test('等待当前频道的 status，并从确认的游标接收后续摘要', () async {
      final messages = <MessageBusMessage>[];
      final finished = Completer<void>();
      bus.subscribe(channel, (message) {
        messages.add(message);
        if ((message.data as Map)['done'] == true) finished.complete();
      });

      var ready = false;
      final cursor = bus.waitForSubscription(channel).then((id) {
        ready = true;
        return id;
      });

      final firstRequest = await adapter.firstRequest.future;
      expect((firstRequest.data as Map)[channel], '-1');
      adapter.send([
        {
          'channel': '/__status',
          'message_id': -1,
          'data': {'/other': 99},
        },
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(ready, isFalse);

      adapter.send([
        {
          'channel': '/__status',
          'message_id': -1,
          'data': {channel: 0},
        },
      ]);
      expect(await cursor, 0);
      expect(messages, isEmpty);

      await adapter.finishResponse();
      final secondRequest = await adapter.secondRequest.future;
      expect((secondRequest.data as Map)[channel], '0');
      adapter.send([
        {
          'channel': channel,
          'message_id': 1,
          'data': {
            'done': false,
            'ai_topic_summary': {'summarized_text': '新的'},
          },
        },
        {
          'channel': channel,
          'message_id': 2,
          'data': {
            'done': true,
            'ai_topic_summary': {'summarized_text': '新的总结'},
          },
        },
      ]);

      await finished.future;
      expect(messages.map((message) => message.messageId), [1, 2]);
      expect(await bus.waitForSubscription(channel), 2);
    });

    test('已有明确游标时无需等待新的 status', () async {
      bus.subscribeWithMessageId(channel, (_) {}, 27);

      expect(await bus.waitForSubscription(channel), 27);
      final request = await adapter.firstRequest.future;
      expect((request.data as Map)[channel], '27');
    });

    test('实际消息也能确认频道游标', () async {
      bus.subscribe(channel, (_) {});
      final cursor = bus.waitForSubscription(channel);
      await adapter.firstRequest.future;
      adapter.send([
        {
          'channel': channel,
          'message_id': 7,
          'data': {'done': false},
        },
      ]);

      expect(await cursor, 7);
    });

    test('游标包含与订阅确认同批到达的旧消息', () async {
      bus.subscribe(channel, (_) {});
      final cursor = bus.waitForSubscription(channel);
      await adapter.firstRequest.future;
      adapter.send([
        {
          'channel': '/__status',
          'message_id': -1,
          'data': {channel: 7},
        },
        {
          'channel': channel,
          'message_id': 8,
          'data': {'done': true},
        },
      ]);

      expect(await cursor, 8);
    });

    test('订阅超时明确报错，不将未确认的频道视为就绪', () async {
      bus.subscribe(channel, (_) {});
      await adapter.firstRequest.future;

      await expectLater(
        bus.waitForSubscription(channel, timeout: Duration.zero),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('取消订阅会结束正在等待的确认', () async {
      void callback(MessageBusMessage message) {}
      bus.subscribe(channel, callback);
      final failure = expectLater(
        bus.waitForSubscription(channel),
        throwsA(isA<StateError>()),
      );
      await adapter.firstRequest.future;

      bus.unsubscribe(channel, callback);

      await failure;
    });

    test('停止全部订阅会结束正在等待的确认', () async {
      bus.subscribe(channel, (_) {});
      final failure = expectLater(
        bus.waitForSubscription(channel),
        throwsA(isA<StateError>()),
      );
      await adapter.firstRequest.future;

      bus.stopAll();

      await failure;
    });
  });
}

class _MessageBusAdapter implements HttpClientAdapter {
  final firstRequest = Completer<RequestOptions>();
  final secondRequest = Completer<RequestOptions>();
  final _responses = <StreamController<Uint8List>>[];

  void send(List<Map<String, dynamic>> messages) {
    _responses.last.add(
      Uint8List.fromList(utf8.encode('${jsonEncode(messages)}\r\n|\r\n')),
    );
  }

  Future<void> finishResponse() => _responses.last.close();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final response = StreamController<Uint8List>();
    _responses.add(response);
    cancelFuture?.then((_) {
      if (!response.isClosed) unawaited(response.close());
    });
    if (_responses.length == 1) firstRequest.complete(options);
    if (_responses.length == 2) secondRequest.complete(options);

    return ResponseBody(
      response.stream,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/plain; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {
    for (final response in _responses) {
      if (!response.isClosed) unawaited(response.close());
    }
  }
}
