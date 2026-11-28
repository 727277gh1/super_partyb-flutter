import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import 'auth_interceptor.dart';

/// PartyB 语音转写 API。
class SpeechApi {
  SpeechApi(this._dio);

  final Dio _dio;

  /// 将完整音频文件上传到 Go API，由服务端调用 Workers AI 转写。
  Future<SpeechTranscription> transcribe({
    required List<int> audio,
    required String filename,
    required String contentType,
  }) async {
    try {
      final response = await _dio.post<dynamic>(
        '/api/speech/transcriptions',
        data: FormData.fromMap({
          'audio': MultipartFile.fromBytes(
            audio,
            filename: filename,
            contentType: DioMediaType.parse(contentType),
          ),
        }),
        options: Options(
          sendTimeout: const Duration(seconds: 90),
          receiveTimeout: const Duration(seconds: 120),
        ),
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        throw HttpError(status, '语音转写请求失败', body: _bodyPreview(response.data));
      }
      return SpeechTranscription.fromJson(_asMap(response.data));
    } on DioException catch (error) {
      throw mapDioError(error);
    }
  }

  Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    throw ParseError('语音转写响应不是 JSON 对象', raw: value is String ? value : null);
  }

  String? _bodyPreview(Object? data) {
    if (data == null) return null;
    final body = data is String ? data : data.toString();
    return body.length > 500 ? '${body.substring(0, 500)}…' : body;
  }
}
