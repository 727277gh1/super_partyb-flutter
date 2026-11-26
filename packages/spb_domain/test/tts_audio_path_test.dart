import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// [parseTTSAudioPath] 的契约测试。
///
/// 对齐后端 `groupsync.turnIDFromPath` 与 webapp `parseTTSAudioPath`，
/// 三处契约必须一致（见 `tts_audio_path.dart` 的契约说明）。
void main() {
  group('语音产物 parseTTSAudioPath', () {
    test('合法 tts 路径识别为语音产物', () {
      final m = parseTTSAudioPath('reports/tts/c7ad0b62/message_6.mp3');
      expect(m, isNotNull);
      expect(m!.turnId, 'c7ad0b62');
      expect(m.kind, TtsStreamKind.reply);
      expect(m.part, 6000);
    });

    test('narration 与 reply 区分', () {
      // reply：speech_ 或 message_ 前缀。
      expect(
        parseTTSAudioPath('reports/tts/t1/speech_t1_1.mp3')!.kind,
        TtsStreamKind.reply,
      );
      expect(
        parseTTSAudioPath('reports/tts/t1/message_3.mp3')!.kind,
        TtsStreamKind.reply,
      );
      // narration：narration_ 前缀。
      expect(
        parseTTSAudioPath('reports/tts/t1/narration_t1_1.mp3')!.kind,
        TtsStreamKind.narration,
      );
      // filesummary：filesummary_ 前缀。
      expect(
        parseTTSAudioPath('reports/tts/t1/filesummary_t1_1.mp3')!.kind,
        TtsStreamKind.filesummary,
      );
    });

    test('x/reports/tts/ 不误判（前缀锚定开头）', () {
      // 前缀必须锚定在路径开头，子路径不算 TTS（对齐后端 turnIDFromPath）。
      expect(
        parseTTSAudioPath('workspace/reports/tts/t1/message_1.mp3'),
        isNull,
      );
      expect(parseTTSAudioPath('/abs/reports/tts/t1/message_1.mp3'), isNull);
    });

    test('turn_id 含非法字符不识别', () {
      // turn_id 仅允许 [A-Za-z0-9_-]。
      expect(parseTTSAudioPath('reports/tts/a b/message_1.mp3'), isNull);
      expect(parseTTSAudioPath('reports/tts/a.b/message_1.mp3'), isNull);
    });

    test('文件名无法解析 part 不识别', () {
      expect(parseTTSAudioPath('reports/tts/t1/random.mp3'), isNull);
    });

    test('part 排序键：message_{seq}[_n] = seq*1000+n', () {
      expect(parseTTSAudioPath('reports/tts/t1/message_2.mp3')!.part, 2000);
      expect(parseTTSAudioPath('reports/tts/t1/message_2_3.mp3')!.part, 2003);
    });

    test('part 排序键：narration_/speech_/filesummary_ 取末段', () {
      expect(parseTTSAudioPath('reports/tts/t1/narration_t1_5.mp3')!.part, 5);
      expect(parseTTSAudioPath('reports/tts/t1/speech_t1_7.mp3')!.part, 7);
    });
  });
}
