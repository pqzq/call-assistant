import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// 麦克风录音：把用户口述的开场白录成 wav
///
/// 录完由上层拷到 `TtsSynthesizer.openingAudioFile()`（固定的开场白音频位置），
/// 和「导入音频文件」走**同一条落盘链路** —— 播报侧不需要知道音频从哪来。
class VoiceRecorder {
  VoiceRecorder._();

  static final VoiceRecorder instance = VoiceRecorder._();

  final AudioRecorder _recorder = AudioRecorder();
  String? _currentPath;
  DateTime? _startedAt;

  bool get isRecording => _currentPath != null;

  /// 已录时长（录音中才有意义）
  Duration get elapsed {
    final started = _startedAt;
    if (started == null) return Duration.zero;
    return DateTime.now().difference(started);
  }

  /// 开始录音。返回 null 表示成功，否则是给用户看的错误原因。
  Future<String?> start() async {
    if (_currentPath != null) return null;
    try {
      if (!await _recorder.hasPermission()) {
        return '没有麦克风权限，请在系统设置里允许录音后重试';
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/opening_rec_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _recorder.start(
        const RecordConfig(
          // wav(PCM16) 兼容性最好：播放（audioplayers）和识别（sherpa）都能直接读
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
      _currentPath = path;
      _startedAt = DateTime.now();
      return null;
    } catch (e) {
      _currentPath = null;
      _startedAt = null;
      return '录音启动失败：$e';
    }
  }

  /// 停止录音，返回 wav 路径（失败返回 null）
  Future<String?> stop() async {
    final path = _currentPath;
    if (path == null) return null;
    _currentPath = null;
    _startedAt = null;
    try {
      final result = await _recorder.stop();
      return result ?? path;
    } catch (_) {
      return null;
    }
  }

  /// 放弃本次录音（并删掉临时文件）
  Future<void> cancel() async {
    final path = _currentPath;
    _currentPath = null;
    _startedAt = null;
    try {
      await _recorder.cancel();
    } catch (_) {
      // ignore
    }
    if (path != null) {
      try {
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
      } catch (_) {
        // ignore
      }
    }
  }

  Future<void> dispose() async {
    try {
      await _recorder.dispose();
    } catch (_) {
      // ignore
    }
  }
}
