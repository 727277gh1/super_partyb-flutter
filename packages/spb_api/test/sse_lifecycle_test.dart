import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() => SpbLog.configure(sink: const NullLogSink()));

  for (final action in ['connect', 'close', 'dispose']) {
    test('旧请求的迟到失败不影响 $action 后的连接状态', () async {
      final adapter = _LifecycleAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final entered = Completer<void>();
      final release = Completer<void>();
      dio.interceptors.add(
        InterceptorsWrapper(
          onError: (error, handler) async {
            if (error.requestOptions.path.endsWith('/old')) {
              entered.complete();
              await release.future;
            }
            handler.next(error);
          },
        ),
      );
      final client = SseClient(dio: dio, baseUrl: 'http://test');
      final errors = <Object>[];
      final frames = <SseFrame>[];
      final subscription = client.frames.listen(
        frames.add,
        onError: errors.add,
      );
      addTearDown(() async {
        await subscription.cancel();
        if (action != 'dispose') await client.dispose();
        dio.close(force: true);
      });
      final old = client.connect(path: '/old');
      await entered.future;
      if (action == 'connect') {
        await client.connect(path: '/new');
      } else if (action == 'close') {
        await client.close();
      } else {
        await client.dispose();
      }
      final stateAfterAction = client.state;
      release.complete();
      await old;
      await Future<void>.delayed(Duration.zero);
      expect(errors, isEmpty, reason: '旧会话的错误不能再进入当前事件流');
      expect(client.state, stateAfterAction);
      if (action == 'connect') {
        expect(adapter.requests.last.cancelToken!.isCancelled, isFalse);
        adapter.streams.last.add(
          Uint8List.fromList(utf8.encode('data: new\n\n')),
        );
        await Future<void>.delayed(Duration.zero);
        expect(frames.map((frame) => frame.data), ['new']);
      }
    });
  }

  for (final action in ['connect', 'resume', 'close', 'switchBaseUrl']) {
    test('$action 等待旧流清理时不覆盖较新的 connect', () async {
      final cancelling = Completer<void>();
      final release = Completer<void>();
      var cancellations = 0;
      final adapter = _LifecycleAdapter(
        onCancel: () {
          if (++cancellations == 1) {
            cancelling.complete();
            return release.future;
          }
          return Future<void>.value();
        },
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final client = SseClient(dio: dio, baseUrl: 'http://test');
      addTearDown(() async {
        await client.dispose();
        dio.close(force: true);
      });
      await client.connect(path: '/initial');
      final pending = switch (action) {
        'connect' => client.connect(path: '/superseded'),
        'resume' => client.resume(),
        'close' => client.close(),
        _ => client.switchBaseUrl('http://next'),
      };
      await cancelling.future;
      await client.connect(path: '/latest', initialCursor: 'latest-cursor');
      release.complete();
      await pending;
      expect(client.state, SseState.connected);
      expect(adapter.requests, hasLength(2));
      expect(adapter.requests.last.path, endsWith('/latest'));
      expect(adapter.requests.last.cancelToken!.isCancelled, isFalse);
      expect(client.lastEventId, 'latest-cursor');
    });
  }

  test('切换端点等待旧流取消时，close 必须胜出', () async {
    final cancelling = Completer<void>();
    final release = Completer<void>();
    final adapter = _LifecycleAdapter(
      onCancel: () {
        if (!cancelling.isCompleted) cancelling.complete();
        return release.future;
      },
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final client = SseClient(dio: dio, baseUrl: 'http://test');
    addTearDown(() async {
      await client.dispose();
      dio.close(force: true);
    });
    await client.connect(path: '/new');
    final switching = client.switchBaseUrl('http://next');
    await cancelling.future;
    final closing = client.close();
    release.complete();
    await Future.wait([switching, closing]);
    expect(client.state, SseState.idle);
    expect(adapter.requests, hasLength(1), reason: '关闭后不得由旧切换操作重新建连');
  });
}

class _LifecycleAdapter implements HttpClientAdapter {
  _LifecycleAdapter({this.onCancel});

  final Future<void> Function()? onCancel;
  final requests = <RequestOptions>[];
  final streams = <StreamController<Uint8List>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.path.endsWith('/old')) {
      throw DioException.badResponse(
        statusCode: 401,
        requestOptions: options,
        response: Response<dynamic>(requestOptions: options, statusCode: 401),
      );
    }
    final stream = StreamController<Uint8List>(onCancel: onCancel);
    streams.add(stream);
    return ResponseBody(
      stream.stream,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
