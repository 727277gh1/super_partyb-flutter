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
}
