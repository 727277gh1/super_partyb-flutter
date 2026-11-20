import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_platform/spb_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.atjog.spb/external_quick_capture');
  const bridge = ExternalQuickCaptureBridge();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('外部文件保留原名并从宿主缓存读取，关闭请求交给临时 Activity', () async {
    final dir = Directory.systemTemp.createTempSync('external-capture-');
    final file = File('${dir.path}/0-cache')..writeAsStringSync('内容');
    addTearDown(() => dir.deleteSync(recursive: true));
    var finished = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'finish') {
        finished = true;
        return null;
      }
      return {
        'text': '看看这个',
        'files': [
          {'path': file.path, 'name': '截图.png'},
        ],
      };
    });
    final capture = (await bridge.load())!;
    expect(capture.text, '看看这个');
    expect(capture.files.single.name, '截图.png');
    expect(capture.files.single.path, file.path);
    expect(await capture.files.single.length(), file.lengthSync());
    expect(finished, isFalse);
    await bridge.finish();
    expect(finished, isTrue);
  });

  test('普通启动无原生入口时保持原导航', () async {
    expect(await bridge.load(), isNull);
  });

  test('磁贴启动只标记待读取，前台页面再单独获取剪贴板', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'load'
          ? {'readClipboard': true}
          : {'text': '刚复制的文字'};
    });
    final launch = (await bridge.load())!;
    expect(launch.readClipboard, isTrue);
    expect(launch.text, isEmpty);
    expect(calls, ['load']);
    final capture = await bridge.readClipboard();
    expect(capture.text, '刚复制的文字');
    expect(capture.files, isEmpty);
    expect(capture.readClipboard, isFalse);
    expect(calls, ['load', 'readClipboard']);
  });

  test('剪贴板读取异常不泄露平台信息，仍允许手动粘贴', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'denied', message: '私有内容');
    });
    final capture = await bridge.readClipboard();
    expect(capture.text, isEmpty);
    expect(capture.error, contains('长按输入框粘贴'));
    expect(capture.error, isNot(contains('私有内容')));
  });
}
