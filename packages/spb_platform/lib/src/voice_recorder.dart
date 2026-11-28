import 'dart:io';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:spb_core/spb_core.dart';

/// 本地录音文件。音频只保存在临时目录，停止录音后由 recorder 读取并删除。
class VoiceRecording {
  const VoiceRecording({
    required this.bytes,
    required this.filename,
    required this.contentType,
  });

  final Uint8List bytes;
  final String filename;
  final String contentType;
}

/// 平台无关的语音录音能力。
abstract interface class VoiceRecorder {
  Future<void> start();

  Future<VoiceRecording> stop();

  Future<void> cancel();

  Future<void> dispose();
}

/// 使用 `record` 插件录制 16 kHz、单声道 WAV。
///
/// WAV 可由 Cloudflare Whisper 直接识别，完整录音一次上传，避免按字节硬切音频。
class RecordVoiceRecorder implements VoiceRecorder {
  RecordVoiceRecorder({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  Directory? _temporaryDirectory;
  String? _recordingPath;
  bool _disposed = false;

  @override
  Future<void> start() async {
    if (_disposed) throw StateError('录音器已释放');
    if (_recordingPath != null) throw StateError('录音已经开始');
    if (!await _recorder.hasPermission()) {
      throw const VoicePermissionDeniedException();
    }

    final directory = await Directory.systemTemp.createTemp('spb-voice-');
    final path = '${directory.path}${Platform.pathSeparator}voice.wav';
    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
      _temporaryDirectory = directory;
      _recordingPath = path;
    } catch (error, stackTrace) {
      SpbLog.warn('启动录音失败，清理临时目录', {'error': '$error', 'stack': '$stackTrace'});
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  @override
  Future<VoiceRecording> stop() async {
    final path = _recordingPath;
    final directory = _temporaryDirectory;
    if (path == null || directory == null) throw StateError('当前没有录音');
    _recordingPath = null;
    _temporaryDirectory = null;
    try {
      final stoppedPath = await _recorder.stop();
      final file = File(stoppedPath ?? path);
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) throw StateError('录音内容为空');
      return VoiceRecording(
        bytes: bytes,
        filename: 'voice.wav',
        contentType: 'audio/wav',
      );
    } finally {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }

  @override
  Future<void> cancel() async {
    final directory = _temporaryDirectory;
    _recordingPath = null;
    _temporaryDirectory = null;
    try {
      if (await _recorder.isRecording()) await _recorder.cancel();
    } finally {
      if (directory != null && await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await cancel();
    await _recorder.dispose();
  }
}

/// 麦克风权限被拒绝。
class VoicePermissionDeniedException implements Exception {
  const VoicePermissionDeniedException();
}

/// 语音录音支持的平台，用于生成对应的系统权限路径。
enum VoicePermissionPlatform { android, ios, macos, windows, linux, other }

/// 当前平台的语音权限设置路径。
VoicePermissionPlatform currentVoicePermissionPlatform() {
  if (Platform.isAndroid) return VoicePermissionPlatform.android;
  if (Platform.isIOS) return VoicePermissionPlatform.ios;
  if (Platform.isMacOS) return VoicePermissionPlatform.macos;
  if (Platform.isWindows) return VoicePermissionPlatform.windows;
  if (Platform.isLinux) return VoicePermissionPlatform.linux;
  return VoicePermissionPlatform.other;
}

/// 返回用户可按图操作的麦克风权限设置路径。
String voicePermissionSettingsInstructions(VoicePermissionPlatform platform) =>
    switch (platform) {
      VoicePermissionPlatform.android => '设置 → 应用 → PartyB → 权限 → 麦克风 → 允许',
      VoicePermissionPlatform.ios => '设置 → PartyB → 麦克风 → 开启',
      VoicePermissionPlatform.macos => '系统设置 → 隐私与安全性 → 麦克风 → 开启 PartyB',
      VoicePermissionPlatform.windows =>
        '设置 → 隐私和安全性 → 麦克风，开启“麦克风访问”和“允许桌面应用访问麦克风”',
      VoicePermissionPlatform.linux =>
        '在桌面环境的隐私或权限设置中允许 PartyB 使用麦克风，并检查系统输入设备已启用',
      VoicePermissionPlatform.other => '系统设置 → 应用权限或隐私设置 → 麦克风，允许 PartyB 访问',
    };
