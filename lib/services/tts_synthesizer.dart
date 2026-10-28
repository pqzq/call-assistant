import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'app_paths.dart';

/// 端侧 TTS：用 sherpa-onnx 把开场白文本合成成 wav，播放端直接播音视频文件，
/// 避免依赖系统 TTS 引擎（很多定制 ROM 不对第三方开放）与播报时的合成延迟。
/// 同时输出振幅包络，供 Live2D 数字人做嘴型同步。
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

  /// 模型存放目录（统一数据根下的 sherpa/tts，Android 可用 adb 直接推送）
  Future<Directory> modelRoot() async {
    final dir = AppPaths.sherpaTtsDir;
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
      final entries = dir.listSync();
      final files = entries.whereType<File>().toList();
      final onnx = files.where((f) => f.path.toLowerCase().endsWith('.onnx')).toList();
      final tokens = files.where((f) => _baseName(f.path) == 'tokens.txt').toList();
      if (onnx.isEmpty || tokens.isEmpty) continue;

      // 主模型 / vocoder 分开（Matcha 有独立的 vocoder.onnx）
      File? modelFile;
      File? vocoderFile;
      String voices = '';
      for (final f in onnx) {
        final name = _baseName(f.path).toLowerCase();
        if (name.contains('vocoder')) {
          vocoderFile ??= f;
        } else {
          modelFile ??= f;
        }
      }
      if (modelFile == null) continue; // 只有 vocoder 组不成模型
      for (final f in files) {
        if (_baseName(f.path).toLowerCase() == 'voices.bin') voices = f.path;
      }

      // 架构判定（按目录里的文件特征，不靠命名约定）：
      //   有 vocoder.onnx         -> Matcha（声学模型 + 声码器分离）
      //   有 voices.bin           -> Kokoro（音色表）
      //   其余                    -> VITS（piper 等都在这一类）
      final TtsArch arch;
      if (vocoderFile != null) {
        arch = TtsArch.matcha;
      } else if (voices.isNotEmpty) {
        arch = TtsArch.kokoro;
      } else {
        arch = TtsArch.vits;
      }
      // 只有 Matcha 必须有 vocoder；Kokoro/VITS 忽略这个字段
      if (arch == TtsArch.matcha && vocoderFile == null) continue;

      // 中文模型常带 jieba 词典目录
      String dictDir = '';
      for (final e in entries) {
        if (e is Directory && _baseName(e.path) == 'dict') dictDir = e.path;
      }

      // Kokoro 多语言模型可以指定语言；放个 lang.txt（内容如 zh / en / ja）即可
      String lang = '';
      final langFile = File('${dir.path}/lang.txt');
      if (langFile.existsSync()) {
        try {
          lang = langFile.readAsStringSync().trim();
        } catch (_) {
          // 读不到就用默认（sherpa 按英文处理）
        }
      }

      _modelDir = modelFile.parent.path;
      _modelConfig = _ModelFiles(
        arch: arch,
        model: modelFile.path,
        vocoder: vocoderFile?.path ?? '',
        voices: voices,
        tokens: tokens.first.path,
        dataDir: Directory('${dir.path}/espeak-ng-data').existsSync()
            ? '${dir.path}/espeak-ng-data'
            : '',
        lexicon: File('${dir.path}/lexicon.txt').existsSync() ? '${dir.path}/lexicon.txt' : '',
        dictDir: dictDir,
        lang: lang,
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

  /// 开场白音频的基名
  ///
  /// 后缀**随实际格式变化**（`opening_audio.mp3` / `.m4a` …）：导入外部音频时
  /// 保留原后缀，用户能一眼看出是什么格式；合成与录音固定产 wav。
  static const String openingAudioBaseName = 'opening_audio';

  /// 支持的开场白音频后缀（也是 `findOpeningAudio` 的查找顺序）
  static const List<String> openingAudioExts = <String>[
    'wav',
    'mp3',
    'm4a',
    'aac',
    'ogg',
    'flac',
    'amr',
  ];

  /// 取文件后缀（小写、不含点）；没有后缀返回空串
  static String extOf(String path) {
    final slash = path.lastIndexOf(Platform.pathSeparator);
    final name = slash >= 0 ? path.substring(slash + 1) : path;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  /// 开场白音频路径（统一数据根下的 audio/ 目录）
  ///
  /// [ext] 默认 wav（合成与录音都产 wav）；导入外部音频时传原后缀。
  static Future<File> openingAudioFile({String ext = 'wav'}) async {
    final dir = AppPaths.audioDir;
    final e = ext.toLowerCase().replaceAll('.', '');
    return File('${dir.path}/$openingAudioBaseName.${e.isEmpty ? 'wav' : e}');
  }

  /// 找到**实际存在**的开场白音频（后缀可能是导入时的原格式）
  static Future<File?> findOpeningAudio() async {
    final dir = AppPaths.audioDir;
    if (!dir.existsSync()) return null;
    for (final ext in openingAudioExts) {
      final f = File('${dir.path}/$openingAudioBaseName.$ext');
      if (f.existsSync()) return f;
    }
    return null;
  }

  /// 删掉除 [keepPath] 之外的同名音频（连同各自的 `.env.json`）
  ///
  /// 换格式后必须清理：否则 `opening_audio.wav` 和 `opening_audio.mp3` 并存，
  /// 启动时按顺序找到哪一个是不确定的。
  static Future<void> removeOtherOpeningAudio(String keepPath) async {
    final dir = AppPaths.audioDir;
    if (!dir.existsSync()) return;
    for (final ext in openingAudioExts) {
      final f = File('${dir.path}/$openingAudioBaseName.$ext');
      if (f.path == keepPath) continue;
      try {
        if (f.existsSync()) await f.delete();
        final env = File('${f.path}.env.json');
        if (env.existsSync()) await env.delete();
      } catch (_) {
        // 忽略（文件被占用等）
      }
    }
  }

  Future<SynthesisResult?> synthesize({required String text, double speed = 1.0}) async {
    final content = text.trim();
    if (content.isEmpty) return null;

    final tts = await _ensureTts();
    if (tts == null) return null;

    final audio = tts.generate(text: content, sid: 0, speed: speed);
    if (audio.samples.isEmpty || audio.sampleRate <= 0) return null;

    // 固定写同一个文件（覆盖），不再每次生成带时间戳的新文件
    final file = await openingAudioFile();
    await file.parent.create(recursive: true);
    await file.writeAsBytes(_encodeWav(audio.samples, audio.sampleRate));

    // 每 50ms 一个 RMS 值，归一化到 0~1，供播放时驱动嘴型
    final envelope = _buildEnvelope(audio.samples, audio.sampleRate, 50);
    await File('${file.path}.env.json').writeAsString(_encodeEnvelope(envelope, audio.sampleRate));

    await _cleanOldOpeningFiles();
    // 合成总是产 wav：清掉之前导入的 mp3/m4a 等，避免两份并存
    await removeOtherOpeningAudio(file.path);

    return SynthesisResult(wavPath: file.path, envelope: envelope, stepMs: 50);
  }

  /// 清理历史遗留的带时间戳的开场白文件
  Future<void> _cleanOldOpeningFiles() async {
    try {
      final dir = AppPaths.audioDir;
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (name.startsWith('opening_tts_') && name.endsWith('.wav')) {
          try {
            entity.deleteSync();
          } catch (_) {
            // 忽略
          }
        }
      }
    } catch (_) {
      // 忽略
    }
  }

  /// 读取 wav 旁边的包络文件（重启后仍可用）
  Future<List<double>?> loadEnvelope(String wavPath) async {
    try {
      final file = File('$wavPath.env.json');
      if (!file.existsSync()) return null;
      final text = await file.readAsString();
      final values = _decodeEnvelope(text);
      if (values == null || values.isEmpty) return null;
      return values;
    } catch (_) {
      return null;
    }
  }

  /// 逐窗计算 RMS 并归一化
  List<double> _buildEnvelope(Float32List samples, int sampleRate, int stepMs) {
    final window = (sampleRate * stepMs / 1000).round().clamp(1, samples.length);
    final result = <double>[];
    for (var start = 0; start < samples.length; start += window) {
      final end = math.min(start + window, samples.length);
      var sum = 0.0;
      for (var i = start; i < end; i++) {
        sum += samples[i] * samples[i];
      }
      result.add(math.sqrt(sum / (end - start)));
    }
    if (result.isEmpty) return result;
    final peak = result.reduce(math.max);
    if (peak <= 0) return List<double>.filled(result.length, 0);
    // 归一化 + 轻微非线性压缩，小音量也能带出嘴型
    return result
        .map((v) => math.min(1.0, math.pow(v / peak, 0.7).toDouble()))
        .toList(growable: false);
  }

  String _encodeEnvelope(List<double> values, int sampleRate) {
    final buffer = StringBuffer()
      ..write('{"stepMs":50,"sampleRate":')
      ..write(sampleRate)
      ..write(',"values":[');
    for (var i = 0; i < values.length; i++) {
      if (i > 0) buffer.write(',');
      buffer.write(values[i].toStringAsFixed(3));
    }
    buffer.write(']}');
    return buffer.toString();
  }

  List<double>? _decodeEnvelope(String text) {
    final start = text.indexOf('"values"');
    if (start < 0) return null;
    final open = text.indexOf('[', start);
    final close = text.lastIndexOf(']');
    if (open < 0 || close <= open) return null;
    final body = text.substring(open + 1, close).trim();
    if (body.isEmpty) return <double>[];
    return body
        .split(',')
        .map((e) => double.tryParse(e.trim()) ?? 0)
        .toList(growable: false);
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

    // 按识别到的架构填对应的 config。
    // 之前写死 vits，导致 kokoro / matcha 的模型即使导入了也用不起来。
    final sherpa.OfflineTtsModelConfig modelConfig;
    switch (files.arch) {
      case TtsArch.matcha:
        modelConfig = sherpa.OfflineTtsModelConfig(
          matcha: sherpa.OfflineTtsMatchaModelConfig(
            acousticModel: files.model,
            vocoder: files.vocoder,
            tokens: files.tokens,
            dataDir: files.dataDir,
            lexicon: files.lexicon,
            dictDir: files.dictDir,
            lengthScale: 1.0,
          ),
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        );
      case TtsArch.kokoro:
        modelConfig = sherpa.OfflineTtsModelConfig(
          kokoro: sherpa.OfflineTtsKokoroModelConfig(
            model: files.model,
            voices: files.voices,
            tokens: files.tokens,
            dataDir: files.dataDir,
            lexicon: files.lexicon,
            dictDir: files.dictDir,
            lang: files.lang,
            lengthScale: 1.0,
          ),
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        );
      case TtsArch.vits:
        modelConfig = sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(
            model: files.model,
            tokens: files.tokens,
            dataDir: files.dataDir,
            lexicon: files.lexicon,
            dictDir: files.dictDir,
            lengthScale: 1.0,
          ),
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        );
    }

    final config = sherpa.OfflineTtsConfig(
      model: modelConfig,
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

/// 合成结果：wav 路径 + 振幅包络
class SynthesisResult {
  const SynthesisResult({
    required this.wavPath,
    required this.envelope,
    required this.stepMs,
  });

  final String wavPath;

  /// 每 [stepMs] 毫秒一个 0~1 的振幅值
  final List<double> envelope;

  final int stepMs;

  Duration get duration => Duration(milliseconds: envelope.length * stepMs);
}

/// TTS 模型架构（按模型目录里的文件特征自动识别）
enum TtsArch {
  /// 单模型（piper / vits-* 等），只需 model + tokens
  vits,

  /// 声学模型 + 独立声码器（acousticModel + vocoder）
  matcha,

  /// 带音色表的模型（model + voices.bin）
  kokoro,
}

class _ModelFiles {
  const _ModelFiles({
    required this.arch,
    required this.model,
    required this.tokens,
    required this.dataDir,
    required this.lexicon,
    this.vocoder = '',
    this.voices = '',
    this.dictDir = '',
    this.lang = '',
  });

  final TtsArch arch;

  /// 主模型：VITS/Kokoro 的 model，Matcha 的 acousticModel
  final String model;

  /// Matcha 专用
  final String vocoder;

  /// Kokoro 专用
  final String voices;

  final String tokens;
  final String dataDir;
  final String lexicon;

  /// jieba 词典目录（中文模型常有）
  final String dictDir;

  /// Kokoro 多语言模型的语言代码（空 = 交给引擎按默认处理）
  final String lang;
}

/// 可下载的推荐 TTS 模型（直链，点了直接下 .tar.bz2）
class TtsModelOption {
  const TtsModelOption({
    required this.name,
    required this.languages,
    required this.note,
  });

  /// 模型名（也是 tar.bz2 的文件名前缀）
  final String name;
  final String languages;
  final String note;

  /// 直链下载地址
  String get url =>
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/$name.tar.bz2';
}

/// 推荐模型清单（与 README 的表格保持一致）
const List<TtsModelOption> kTtsModelOptions = <TtsModelOption>[
  TtsModelOption(
    name: 'vits-piper-zh_CN-xiao_ya-medium-int8',
    languages: '中文',
    note: '最省空间（约 13MB），日常播报够用',
  ),
  TtsModelOption(
    name: 'kokoro-multi-lang-v1_1',
    languages: '中 / 英 / 日 / 法 / 西 / 印地 / 意 / 葡',
    note: '音质明显更好，但体积大（int8 约 86MB），合成也慢一些',
  ),
  TtsModelOption(
    name: 'matcha-icefall-zh-en',
    languages: '中英混读',
    note: '一句话里中英夹杂读得自然（包里含 vocoder）',
  ),
];
