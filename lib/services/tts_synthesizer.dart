import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// 端侧 TTS：用 sherpa-onnx 把开场白文本合成成 wav，播放端直接播音视频文件，
/// 避免依赖系统 TTS 引擎（很多定制 ROM 不对第三方开放）与播报时的合成延迟。
class TtsSynthesizer {
  TtsSynthesizer._();

  static final TtsSynthesizer instance = TtsSynthesizer._();

  /// 推荐模型（int8 量化，约 13.4MB，含 espeak 数据）
  static const String recommendedModel = 'vits-piper-zh_CN-xiao_ya-medium-int8';
  static const String modelDownloadPage =
      'https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models';

  bool _bindingsReady = false;
  sherpa.OfflineTts? _tts;
  String? _modelDir;

  bool get isModelReady => _modelDir != null;
  String? get modelDir => _modelDir;

  /// 模型存放目录（external files，可用 adb 直接推送）
  Future<Directory> modelRoot() async {
    Directory? base;
    try {
      base = await getExternalStorageDirectory();
    } catch (_) {
      base = null;
    }
    base ??= await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/sherpa-tts');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 扫描模型目录，找到可用的模型（含 onnx + tokens.txt 的子目录）
  Future<String?> detectModel() async {
    final root = await modelRoot();
    if (!root.existsSync()) return null;

    final candidates = <Directory>[root];
    for (final entity in root.listSync()) {
      if (entity is Directory) candidates.add(entity);
    }

    for (final dir in candidates) {
      final files = dir.listSync().whereType<File>().toList();
      final onnx = files.where((f) => f.path.toLowerCase().endsWith('.onnx')).toList();
      final tokens = files.where((f) => _baseName(f.path) == 'tokens.txt').toList();
      if (onnx.isEmpty || tokens.isEmpty) continue;
      final modelFile = onnx.firstWhere(
        (f) => !_baseName(f.path).contains('vocoder'),
        orElse: () => onnx.first,
      );
      _modelDir = modelFile.parent.path;
      _modelConfig = _ModelFiles(
        model: modelFile.path,
        tokens: tokens.first.path,
        dataDir: Directory('${dir.path}/espeak-ng-data').existsSync()
            ? '${dir.path}/espeak-ng-data'
            : '',
        lexicon: File('${dir.path}/lexicon.txt').existsSync() ? '${dir.path}/lexicon.txt' : '',
      );
      return _modelDir;
    }
    _modelDir = null;
    _modelConfig = null;
    return null;
  }

  _ModelFiles? _modelConfig;

  /// 导入模型压缩包（.tar.bz2），解压后自动识别
  Future<String?> importArchive(File archiveFile, {void Function(double)? onProgress}) async {
    final root = await modelRoot();
    final bytes = await archiveFile.readAsBytes();
    onProgress?.call(0.3);

    final decompressed = BZip2Decoder().decodeBytes(bytes);
    onProgress?.call(0.6);

    final archive = TarDecoder().decodeBytes(decompressed);
    onProgress?.call(0.7);

    for (final entry in archive) {
      if (!entry.isFile) continue;
      final outFile = File('${root.path}/${entry.name}');
      outFile.parent.createSync(recursive: true);
      outFile.writeAsBytesSync(entry.content as List<int>);
    }
    onProgress?.call(1.0);
    return detectModel();
  }

  /// 合成语音，返回生成的 wav 路径
  Future<String?> synthesize({required String text, double speed = 1.0}) async {
    final content = text.trim();
    if (content.isEmpty) return null;

    final tts = await _ensureTts();
    if (tts == null) return null;

    final audio = tts.generate(text: content, sid: 0, speed: speed);
    if (audio.samples.isEmpty || audio.sampleRate <= 0) return null;

    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/opening_tts_${DateTime.now().millisecondsSinceEpoch}.wav');
    await file.writeAsBytes(_encodeWav(audio.samples, audio.sampleRate));
    return file.path;
  }

  Future<sherpa.OfflineTts?> _ensureTts() async {
    if (_tts != null) return _tts;

    if (_modelDir == null || _modelConfig == null) {
      await detectModel();
    }
    final files = _modelConfig;
    if (files == null) return null;

    if (!_bindingsReady) {
      await sherpa.initBindingsAsync();
      _bindingsReady = true;
    }

    final config = sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        vits: sherpa.OfflineTtsVitsModelConfig(
          model: files.model,
          tokens: files.tokens,
          dataDir: files.dataDir,
          lexicon: files.lexicon,
          lengthScale: 1.0,
        ),
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      ),
      maxNumSenetences: 1,
    );

    _tts = sherpa.OfflineTts(config);
    return _tts;
  }

  void dispose() {
    _tts?.free();
    _tts = null;
  }

  /// Float32 采样转 16bit PCM WAV
  Uint8List _encodeWav(Float32List samples, int sampleRate) {
    final dataSize = samples.length * 2;
    final buffer = ByteData(44 + dataSize);
    void writeString(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        buffer.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    writeString(0, 'RIFF');
    buffer.setUint32(4, 36 + dataSize, Endian.little);
    writeString(8, 'WAVE');
    writeString(12, 'fmt ');
    buffer.setUint32(16, 16, Endian.little); // PCM 头长度
    buffer.setUint16(20, 1, Endian.little); // PCM
    buffer.setUint16(22, 1, Endian.little); // 单声道
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, sampleRate * 2, Endian.little); // 字节率
    buffer.setUint16(32, 2, Endian.little); // 块对齐
    buffer.setUint16(34, 16, Endian.little); // 位深
    writeString(36, 'data');
    buffer.setUint32(40, dataSize, Endian.little);

    var offset = 44;
    for (final sample in samples) {
      final clamped = math.max(-1.0, math.min(1.0, sample));
      buffer.setInt16(offset, (clamped * 32767).round(), Endian.little);
      offset += 2;
    }
    return buffer.buffer.asUint8List();
  }

  String _baseName(String path) {
    final index = path.lastIndexOf(Platform.pathSeparator);
    return index >= 0 ? path.substring(index + 1) : path;
  }
}

class _ModelFiles {
  const _ModelFiles({
    required this.model,
    required this.tokens,
    required this.dataDir,
    required this.lexicon,
  });

  final String model;
  final String tokens;
  final String dataDir;
  final String lexicon;
}
