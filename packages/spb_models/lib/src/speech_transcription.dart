/// PartyB 语音识别接口返回的转写文本。
class SpeechTranscription {
  const SpeechTranscription({required this.text});

  final String text;

  factory SpeechTranscription.fromJson(Map<String, dynamic> json) {
    final text = json['text'];
    if (text is! String) {
      throw FormatException('语音识别响应缺少 text 字段：${text.runtimeType}');
    }
    return SpeechTranscription(text: text);
  }
}
