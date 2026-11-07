/// `_asMap` 必须**大声失败**，不能把结构不符降级成空模型（issue #69）。
///
/// ## 这个测试防的是什么
///
/// `ChatApi._asMap()` 在响应体不是 JSON 对象时曾返回 `const {}`。因为全部
/// 调用点都是 `Xxx.fromJson(_asMap(res))`，于是任何形状漂移都会产出一个
/// **字段全空的合法对象**：界面上是「这个对话没有标题 / 没有消息」，日志里
/// 什么都没有，而服务端其实返回的是一段 HTML 错误页或一个数组。
///
/// 本仓库在同一条链路上已经选了「大声失败」（`_unwrap` 对非 2xx 抛
/// [HttpError]、UFS 分页超限抛 [ParseError]），`_asMap` 是唯一一处相反取向。
///
/// ## 为什么用真实 server 而不是 DioAdapter
///
/// 要复现的是「200 + 非对象响应体」这条**内容协商/网关改写**路径：
/// DioAdapter 的 mock 直接给 Dart 对象，绕过了 JSON 解码，造不出
/// 「body 是 HTML 文本」这个形状。与 `chat_api_contract_test.dart` 同一取向。
library;

import 'dart:convert';
import 'dart:io';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

/// 对每个请求原样返回 [body]（不假定它是 JSON 对象）。
Future<(HttpServer, Future<void> Function())> startRawServer(
  String body, {
  String contentType = 'text/html',
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    req.response
      ..statusCode = 200
      // charset 必须显式给 utf-8：`ContentType.parse('application/json')` 默认
      // latin1，`write()` 遇到中文会抛 `Invalid argument (string): Contains
      // invalid characters`——而那个异常发生在响应头之前，客户端只会看到
      // 「Connection closed before full header received」，与要测的契约漂移无关。
      ..headers.contentType = ContentType.parse(
        contentType.contains('charset')
            ? contentType
            : '$contentType; charset=utf-8',
      )
      ..write(body);
    await req.response.close();
  });
  return (server, () => server.close(force: true));
}

ChatApi apiAt(HttpServer server) =>
    ChatApi(createDio(baseUrl: 'http://127.0.0.1:${server.port}'));

const _groupShape = {
  'id': 'grp_1',
  'user_id': 'usr_1',
  'title': '周报讨论',
  'status': 'active',
  'created_at': '2024-03-05T08:09:10Z',
};

void main() {
  test('200 + HTML 错误页 → 抛 ParseError，不是「标题为空的对话」（issue #69）', () async {
    final (server, close) = await startRawServer(
      '<!DOCTYPE html><html><body>502 Bad Gateway</body></html>',
    );
    addTearDown(close);

    await expectLater(
      apiAt(server).getGroup('grp_1'),
      throwsA(
        isA<ParseError>().having(
          (e) => e.message,
          'message',
          contains('响应不是 JSON 对象'),
        ),
      ),
      reason: '静默降级会让网关故障表现为「这个对话没有标题」，无从排查',
    );
  });

  test('200 + JSON 数组 → 同样抛 ParseError', () async {
    final (server, close) = await startRawServer(
      jsonEncode([_groupShape]),
      contentType: 'application/json',
    );
    addTearDown(close);

    await expectLater(
      apiAt(server).getGroup('grp_1'),
      throwsA(isA<ParseError>()),
      reason: '端点改成返回数组是契约漂移的典型形态，必须暴露而不是空对象',
    );
  });

  test('反向：正常对象仍要解析成功（避免修成「一律抛」）', () async {
    final (server, close) = await startRawServer(
      jsonEncode(_groupShape),
      contentType: 'application/json',
    );
    addTearDown(close);

    final group = await apiAt(server).getGroup('grp_1');
    expect(group.id, 'grp_1');
    expect(group.title, '周报讨论');
  });

  test('非 Map 但可收窄的响应（顶层是对象，键为任意类型）仍可解析', () async {
    // `_asMap` 的第二分支（`v is Map` → Map<String, dynamic>.from）负责这种
    // 形状。它必须继续可用，否则 dio 在某些解码路径下给出的
    // `Map<dynamic, dynamic>` 会被误判成契约漂移。
    final (server, close) = await startRawServer(
      jsonEncode(Map<dynamic, dynamic>.of(_groupShape)),
      contentType: 'application/json',
    );
    addTearDown(close);

    expect((await apiAt(server).getGroup('grp_1')).title, '周报讨论');
  });
}
