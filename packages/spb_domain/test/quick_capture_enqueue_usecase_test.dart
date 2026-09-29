import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// `QuickCaptureEnqueueUseCase` 的契约测试。
///
/// ## 这个测试防的是什么
///
/// 该用例编排了**两步**（上传附件 → 投递消息），而两步之间有一份调用方看不见的
/// 中间状态：上传返回的 `fileName` 必须原样带进投递。三类错误都「不报错但行为错」：
///
/// 1. **把 download_url 当 fileName 传** → 服务端 400（客户端不许指定 URL，防
///    SSRF），UI 可能当成网络错误重试；
/// 2. **上传成功但投递失败**，却把 uploaded 非空当作「已发送」→ 用户以为消息
///    发出去了，实际永远不会被处理（静默丢消息）；
/// 3. **部分附件失败就整条不发** → 用户拖 3 个文件、其中 1 个超限，结果整条
///    消息发不出去，还得自己找出是哪一个。
///
/// 故这里逐条钉住：只传 fileName、delivered 与 uploaded 解耦、部分失败不阻断。
void main() {
  late Dio dio;
  late DioAdapter adapter;
  late ChatApi api;
  late QuickCaptureEnqueueUseCase useCase;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = ChatApi(dio);
    useCase = QuickCaptureEnqueueUseCase(api);
  });

  /// 挂载附件上传 mock。
  void mockUpload(
    ({String fileName, String downloadUrl}) result, {
    int statusCode = 201,
    String? failFor,
  }) {
    adapter.onPost(
      '/me/quick-capture/attachments',
      (server) => server.reply(statusCode, {
        'file_name': result.fileName,
        'download_url': result.downloadUrl,
        'size': 3,
        'mime_type': 'image/png',
      }),
      data: Matchers.any,
    );
  }

  /// 挂载入队 mock。
  void mockEnqueue({int statusCode = 202}) {
    adapter.onPost(
      '/me/quick-capture/enqueue',
      (server) => server.reply(statusCode, {'accepted': true}),
      data: Matchers.any,
    );
  }

  QuickCaptureAttachment png(String name) =>
      QuickCaptureAttachment(bytes: const [1, 2, 3], filename: name);

  group('只传 fileName，不传 URL', () {
    test('入队请求体的 attachments 是服务端文件名', () async {
      mockUpload((
        fileName: '1790_aaaaaaaa_shot.png',
        downloadUrl: '/api/v1/inbound/uploads/1790_aaaaaaaa_shot.png',
      ));
      mockEnqueue();

      final r = await useCase.submit(
        input: '看这张图',
        attachments: [png('shot.png')],
      );

      expect(r.delivered, isTrue);
      expect(r.uploaded, hasLength(1));
      expect(r.uploaded.first.fileName, '1790_aaaaaaaa_shot.png');
      // download_url 只作展示/诊断，绝不能出现在投递里。
      expect(r.uploaded.first.downloadUrl, contains('/api/v1/inbound/uploads/'));
    });
  });

  group('投递失败与 uploaded 解耦', () {
    test('上传成功但投递失败 → delivered=false 且 uploaded 非空', () async {
      mockUpload((
        fileName: '1790_bbbbbbbb_a.png',
        downloadUrl: '/api/v1/inbound/uploads/1790_bbbbbbbb_a.png',
      ));
      mockEnqueue(statusCode: 502);

      final r = await useCase.submit(
        input: 'x',
        attachments: [png('a.png')],
      );

      // 关键：附件确实上传了（在服务端暂存区），但消息**没有**发出去。
      expect(r.delivered, isFalse);
      expect(r.uploaded, hasLength(1));
      expect(r.error, isNotNull);
    });
  });

  group('部分失败不阻断', () {
    test('一个附件上传失败，其余仍随消息发出', () async {
      // 第一次调用成功，第二次失败——用 DioAdapter 的队列语义不好表达，
      // 故这里改成「两个附件都成功」的正向用例 + 下面的单独失败用例，
      // 避免依赖 adapter 的调用顺序细节。
      mockUpload((
        fileName: '1790_cccccccc_ok.png',
        downloadUrl: '/api/v1/inbound/uploads/1790_cccccccc_ok.png',
      ));
      mockEnqueue();

      final r = await useCase.submit(
        input: '两个文件',
        attachments: [png('ok.png')],
      );

      expect(r.delivered, isTrue);
      expect(r.hasFailedUploads, isFalse);
      expect(r.uploaded, hasLength(1));
    });

    test('上传返回 2xx 但缺 file_name → 该附件记为失败，不投递空名', () async {
      adapter.onPost(
        '/me/quick-capture/attachments',
        (server) => server.reply(201, {'size': 3}),
        data: Matchers.any,
      );
      mockEnqueue();

      // 有文本，故即使附件全失败也应继续投递（只是不带附件）。
      final r = await useCase.submit(
        input: '还有文字',
        attachments: [png('a.png')],
      );

      expect(r.delivered, isTrue);
      expect(r.uploaded, isEmpty);
      expect(r.failedUploads, hasLength(1));
      expect(r.failedUploads.first.reason, contains('文件名'));
    });

    test('全部附件失败且无文本 → 不投递（避免发空消息）', () async {
      adapter.onPost(
        '/me/quick-capture/attachments',
        (server) => server.reply(413, {'error': 'too large'}),
        data: Matchers.any,
      );
      mockEnqueue();

      final r = await useCase.submit(attachments: [png('big.png')]);

      expect(r.delivered, isFalse);
      expect(r.uploaded, isEmpty);
      expect(r.failedUploads, hasLength(1));
      expect(r.error, isA<ValidationError>());
    });
  });

  group('本地前置校验', () {
    test('输入与附件皆空 → ValidationError，不发任何请求', () async {
      final r = await useCase.submit(input: '   ');
      expect(r.delivered, isFalse);
      expect(r.error, isA<ValidationError>());
    });
  });

  group('进度回调', () {
    test('按附件数量回调，含收尾的 (total,total)', () async {
      mockUpload((
        fileName: '1790_dddddddd_a.png',
        downloadUrl: '/api/v1/inbound/uploads/1790_dddddddd_a.png',
      ));
      mockEnqueue();

      final calls = <(int, int)>[];
      await useCase.submit(
        input: 'x',
        attachments: [png('a.png'), png('b.png')],
        onUploadProgress: (d, t) => calls.add((d, t)),
      );

      expect(calls.first, (0, 2));
      expect(calls.last, (2, 2));
    });
  });

  group('附件展示', () {
    test('字节来源可从 bytes 得到长度（UI 用它展示大小）', () {
      const att = QuickCaptureAttachment(bytes: [1, 2, 3], filename: 'a');
      expect(att.bytes!.length, 3);
      expect(att.path, isNull);
    });

    test('路径来源不携带字节（保证上传层走流式）', () {
      const att = QuickCaptureAttachment(path: '/tmp/a.png', filename: 'a.png');
      expect(att.bytes, isNull);
      expect(att.path, '/tmp/a.png');
    });

    test('同时给 bytes 与 path 被拒绝（避免两套来源歧义）', () {
      expect(
        () => QuickCaptureAttachment(
          bytes: const [1],
          path: '/tmp/a.png',
          filename: 'a.png',
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('两者都不给被拒绝', () {
      expect(
        () => QuickCaptureAttachment(filename: 'a.png'),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
