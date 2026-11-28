import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

void main() {
  late Dio dio;
  late DioAdapter adapter;
  late SpeechApi api;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = SpeechApi(dio);
  });

  test('上传完整 WAV 并解析返回文本', () async {
    adapter.onPost(
      '/api/speech/transcriptions',
      (server) => server.reply(200, {'text': '你好，PartyB。'}),
      data: Matchers.formData(
        FormData.fromMap({
          'audio': MultipartFile.fromBytes(
            [1, 2, 3, 4],
            filename: 'voice.wav',
            contentType: DioMediaType.parse('audio/wav'),
          ),
        }),
      ),
    );

    final result = await api.transcribe(
      audio: [1, 2, 3, 4],
      filename: 'voice.wav',
      contentType: 'audio/wav',
    );

    expect(result.text, '你好，PartyB。');
  });

  test('保留服务端的用户可读业务错误', () async {
    adapter.onPost(
      '/api/speech/transcriptions',
      (server) => server.reply(503, {'error': '语音识别未配置，请联系管理员'}),
      data: Matchers.isA<FormData>(),
    );

    await expectLater(
      api.transcribe(
        audio: [1],
        filename: 'voice.wav',
        contentType: 'audio/wav',
      ),
      throwsA(
        isA<HttpError>().having((error) => error.statusCode, 'statusCode', 503),
      ),
    );
  });

  test('响应缺少 text 时显式失败', () async {
    adapter.onPost(
      '/api/speech/transcriptions',
      (server) => server.reply(200, {'transcript': 'unexpected'}),
      data: Matchers.isA<FormData>(),
    );

    await expectLater(
      api.transcribe(
        audio: [1],
        filename: 'voice.wav',
        contentType: 'audio/wav',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
