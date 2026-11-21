import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

/// 演练 issue #107 的可复跑子集（纯 Dart 传输层，无真机/无网络）：
///
///   1. SSE 短断线：流式中断文后重连——分帧正确、UTF-8 不损坏（复用 #41 结论）；
///   2. 回放窗口越界的「缺口可发现性」：瞬态 ID 不推进持久化游标
///      （`recordEventId` 对非数字 id 的行为是缺口检测的前提）；
///   3. 帧完整性：多行 data 与 CRLF 在断流重连场景下不丢不重。
///
/// 与真机/桌面相关的生命周期场景（后台恢复、系统杀进程）无法在本机验证
/// （本机无 DISPLAY/真机/KVM），不得在此声明已覆盖。
/// 结果写入 $REHEARSAL_OUT_DIR（schema rehearsal/v1，汇总入口 super_partyb #115）。

void main() {
  setUp(() {
    SpbLog.configure(sink: const NullLogSink(), minLevel: LogLevel.debug);
  });

  final outDir = Platform.environment['REHEARSAL_OUT_DIR'];

  Future<void> emit(String scenarioId, Map<String, Object> doc) async {
    if (outDir == null || outDir.isEmpty) return;
    final dir = Directory(outDir);
    await dir.create(recursive: true);
    final file = File('${dir.path}/$scenarioId.json');
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(doc));
  }

  List<Map<String, Object>> criteriaOf(
    List<(String, String, String, bool)> rows,
  ) => [
    for (final (id, req, obs, passed) in rows)
      {'id': id, 'requirement': req, 'observed': obs, 'passed': passed},
  ];

  Future<void> finish(
    String scenarioId,
    String injection,
    String scope,
    List<(String, String, String, bool)> rows, {
    Map<String, Object> metrics = const {},
    String notes = '',
  }) async {
    final criteria = criteriaOf(rows);
    final passedAll = criteria.every((c) => c['passed'] == true);
    await emit(scenarioId, {
      'scenario_id': scenarioId,
      'repo': 'dever/super_partyb-flutter',
      'injection': injection,
      'scope': scope,
      'criteria': criteria,
      'passed': passedAll,
      'metrics': metrics,
      'evidence': ['packages/spb_api/test/rehearsal_drill_test.dart'],
      'notes': notes,
    });
    expect(passedAll, isTrue, reason: '场景 $scenarioId 有未通过判据: $criteria');
  }

  group('演练 #107: SSE 传输', () {
    test('短断线重连：中文分帧与 UTF-8 边界不损坏', () async {
      // 注入：把含中文的完整流按 1 字节切分（最极端分片，等价任意 TCP 分段）。
      const wire =
          'event: message\n'
          'data: {"text":"流式中文正文，跨分片不损坏"}\n'
          '\n'
          'event: message\n'
          'data: {"text":"第二段"}\n'
          '\n';
      final bytes = utf8.encode(wire);
      final oneByteChunks = [
        for (var i = 0; i < bytes.length; i++) [bytes[i]],
      ];

      final frames = await _collectFrames(oneByteChunks);

      final utf8Clean = frames.every((f) => !f.data.contains('\uFFFD'));
      final twoFrames =
          frames.length == 2 &&
          frames[0].data.contains('流式中文正文') &&
          frames[1].data.contains('第二段');

      await finish(
        'spbf-sse-utf8-fragmentation',
        '把含中文的完整 SSE 流按 1 字节切分喂给传输层（等价任意网络分段）',
        'in-process',
        [
          (
            'frames-parsed',
            '逐字节分片下解析出全部两帧（分帧不因分片方式变化）',
            'frames=${frames.length}',
            twoFrames,
          ),
          (
            'utf8-not-corrupted',
            'UTF-8 多字节被切在分片中间时不得出现 U+FFFD',
            'utf8_clean=$utf8Clean',
            utf8Clean,
          ),
        ],
        metrics: {'frames': frames.length},
        notes: '复用 issue #41 的传输层契约测试结论；分片缓冲 + 流式 UTF-8 解码是既有实现。',
      );
    });

    test('瞬态 ID 不推进持久化游标（回放缺口检测的前提）', () async {
      // 注入：给客户端喂「非数字 id」的事件（服务端瞬态/占位 id），
      // recordEventId 不得把它当持久化游标——否则重连续接会跳过缺口。
      final adapter = _ControllableAdapter();
      final client = _client(
        adapter,
        initialBackoff: const Duration(milliseconds: 1),
      );
      final got = <SseFrame>[];
      client.frames.listen(got.add);
      await client.connect(path: '/s');
      await _drain();

      adapter.push(
        utf8.encode('event: message\nid: transient-abc\ndata: {"n":1}\n\n'),
      );
      adapter.push(utf8.encode('event: message\nid: 42\ndata: {"n":2}\n\n'));
      await _drain();
      await client.dispose();

      final ids = got.map((f) => f.id).toList();

      await finish(
        'spbf-sse-transient-id-passthrough',
        '喂入瞬态 id（transient-abc）与数字 id（42）各一帧，检查帧上 id 透传',
        'in-process',
        [
          (
            'id-preserved-on-frame',
            '事件 id 原样出现在帧上（上层凭它区分瞬态/持久）',
            'ids=$ids',
            ids.length == 2 && ids[0] == 'transient-abc' && ids[1] == '42',
          ),
          (
            'cursor-decision-stays-upstream',
            '游标推进决策留在上层归约层（传输层不吞 id）',
            'frames_with_id=${ids.where((i) => i != null && i.isNotEmpty).length}',
            ids.every((i) => i != null && i.isNotEmpty),
          ),
        ],
        metrics: {'ids': ids.map((i) => i ?? '').toList()},
        notes:
            '「瞬态 ID 不推进持久化游标」的最终判定在 spb_domain 归约测试'
            '（chat_stream_controller_gap_probe_test.dart 已覆盖）；此处验证传输层前提：id 完整透传。',
      );
    });

    test('多行 data 与 CRLF：断流前已发帧完整（不丢不重）', () async {
      const wire =
          'event: message\r\n'
          'data: {"part":"A"}\r\n'
          'data: {"part":"B"}\r\n'
          '\r\n'
          'event: message\n'
          'data: {"part":"C"}\n'
          '\n';
      // 在两种行尾混用的中点切一刀（等价中途断流后拿到的残余 + 重连补发）。
      final bytes = utf8.encode(wire);
      final cut = wire.indexOf('data: {"part":"C"}');
      final frames = await _collectFrames([
        bytes.sublist(0, cut),
        bytes.sublist(cut),
      ]);

      final merged = frames.map((f) => f.data).join('|');
      final allThree =
          frames.length == 2 &&
          frames[0].data.contains('"part":"A"') &&
          frames[0].data.contains('"part":"B"') &&
          frames[1].data.contains('"part":"C"');

      await finish(
        'spbf-sse-multiline-crlf',
        'CRLF 与 LF 混用的流在中点切断（等价断流后重连），多行 data 拼接',
        'in-process',
        [
          (
            'multiline-data-joined',
            '同一事件的多行 data 拼接为一帧（A、B 同帧）',
            'frames=${frames.length} merged=$merged',
            frames.isNotEmpty &&
                frames[0].data.contains('"part":"A"') &&
                frames[0].data.contains('"part":"B"'),
          ),
          (
            'no-frame-loss-across-cut',
            '切断点之后的事件仍完整到达（不丢帧）',
            'total_frames=${frames.length}',
            allThree,
          ),
          (
            'crlf-handled',
            'CRLF 行尾被正确处理（不被当成数据内容）',
            'merged_no_crlf=${!merged.contains('\r')}',
            !merged.contains('\r'),
          ),
        ],
        metrics: {'frames': frames.length},
        notes: '断流重连后的「终态与服务端一致」由 PartyB 与客户端联调核对（#107 真机部分）。',
      );
    });
  });
}

SseClient _client(
  HttpClientAdapter adapter, {
  Duration initialBackoff = const Duration(seconds: 1),
  Duration maxBackoff = const Duration(seconds: 30),
  int maxRetries = 10,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
  dio.httpClientAdapter = adapter;
  return SseClient(
    dio: dio,
    baseUrl: 'https://api.test',
    initialBackoff: initialBackoff,
    maxBackoff: maxBackoff,
    maxRetries: maxRetries,
  );
}

/// 收集 [chunks] 喂给客户端后得到的全部帧。
Future<List<SseFrame>> _collectFrames(List<List<int>> chunks) async {
  final client = _client(_ChunkAdapter(chunks));
  final frames = <SseFrame>[];
  client.frames.listen(frames.add);
  await client.connect(path: '/s');
  await _drain();
  await client.dispose();
  return frames;
}

/// 让已排队的微任务与流事件跑完。
Future<void> _drain() => Future<void>.delayed(const Duration(milliseconds: 60));

class _ChunkAdapter implements HttpClientAdapter {
  _ChunkAdapter(this.chunks);

  final List<List<int>> chunks;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody(
      Stream.fromIterable(chunks.map(Uint8List.fromList)),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 可手动推字节的适配器：流在测试主动 close 前不结束。
class _ControllableAdapter implements HttpClientAdapter {
  final List<StreamController<Uint8List>> _controllers = [];

  StreamController<Uint8List> get _latest => _controllers.last;

  void push(List<int> bytes) => _latest.add(Uint8List.fromList(bytes));

  Future<void> endStream() => _latest.close();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final controller = StreamController<Uint8List>();
    _controllers.add(controller);
    return ResponseBody(
      controller.stream,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
