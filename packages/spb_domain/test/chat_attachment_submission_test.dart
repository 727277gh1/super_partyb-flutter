import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

import 'support/chat_stream_controller_harness.dart';

void main() {
  setUpHarness();

  test('普通对话上传后带 file_context 发送，响应丢失重试复用文件与幂等键', () async {
    final uploads = <FormData>[];
    final messages = <Map<String, dynamic>>[];
    var failSend = true;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.data is FormData) {
            uploads.add(options.data as FormData);
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'group_id': 'grp_1',
                  'file': {'id': 'file_1'},
                },
              ),
            );
          } else {
            messages.add(Map<String, dynamic>.from(options.data as Map));
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: failSend ? 503 : 200,
                data: failSend
                    ? {'error': '重试'}
                    : {
                        'group_id': 'grp_1',
                        'turn_id': 'turn_1',
                        'status': 'queued',
                      },
              ),
            );
          }
        },
      ),
    );
    final store = FakeOutboxStore();
    final controller = ChatStreamController(
      sse: sse,
      api: api,
      userId: 'usr_1',
      outbox: queueFor(store),
    );
    addTearDown(controller.dispose);
    final draft = ChatAttachmentSubmission(
      input: '',
      attachments: [
        const QuickCaptureAttachment(filename: '../报告.txt', bytes: [65]),
      ],
    );
    await expectLater(
      draft.send(
        api: api,
        controller: controller,
        groupId: 'grp_1',
        agentId: 'a1',
      ),
      throwsA(isA<HttpError>()),
    );
    expect(store.rows, isEmpty, reason: '附件不能降级成只有文字的离线消息');
    failSend = false;
    await draft.send(
      api: api,
      controller: controller,
      groupId: 'grp_1',
      agentId: 'a2',
    );
    expect(uploads, hasLength(1));
    expect(uploads.single.files.single.value.filename, '报告.txt');
    expect(uploads.single.fields.single.value, endsWith('/0-报告.txt'));
    expect(messages, hasLength(2));
    expect(messages.first, messages.last);
    expect(messages.last['file_context'], [
      {'file_id': 'file_1'},
    ]);
    expect(messages.last['group_id'], 'grp_1');
    expect(messages.last['agent_id'], 'a1');
    expect(messages.last['routing'], {'mode': 'manual'});
    expect(messages.last['input'], '请查看附件。');
    await expectLater(
      draft.send(api: api, controller: controller, groupId: 'grp_other'),
      throwsStateError,
    );
  });

  test('上传失败不提交消息，重试从失败文件继续，同名附件路径独立', () async {
    final paths = <String>[];
    var failSecond = true;
    var sent = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.data is FormData) {
            paths.add((options.data as FormData).fields.single.value);
            final fail = failSecond && paths.length == 2;
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: fail ? 413 : 200,
                data: fail
                    ? {'error': '文件太大'}
                    : {
                        'group_id': 'grp_1',
                        'file': {'id': 'file_${paths.length}'},
                      },
              ),
            );
          } else {
            sent++;
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'group_id': 'grp_1',
                  'turn_id': 'turn_1',
                  'status': 'queued',
                },
              ),
            );
          }
        },
      ),
    );
    final controller = ChatStreamController(
      sse: sse,
      api: api,
      userId: 'usr_1',
    );
    addTearDown(controller.dispose);
    final draft = ChatAttachmentSubmission(
      input: '比较文件',
      attachments: [
        const QuickCaptureAttachment(filename: '同名.txt', bytes: [65]),
        const QuickCaptureAttachment(filename: '同名.txt', bytes: [66]),
      ],
    );
    await expectLater(
      draft.send(api: api, controller: controller, groupId: 'grp_1'),
      throwsA(isA<HttpError>()),
    );
    expect(sent, 0);
    failSecond = false;
    await draft.send(api: api, controller: controller, groupId: 'grp_1');
    expect(paths, hasLength(3));
    expect(paths[0], isNot(paths[1]));
    expect(paths[1], paths[2]);
    expect(sent, 1);
  });
}
