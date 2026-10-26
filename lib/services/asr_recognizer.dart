import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'app_paths.dart';
import 'platform_bridge.dart';

/// 端侧离线语音识别（ASR）：把开场白音频识别成中文文本。
///
/// 与端侧合成（TtsSynthesizer）同一套技术栈：
/// - 模型用 sherpa-onnx 的离线识别器（SenseVoice / ParaFormer）
/// - 模型包用 .tar.bz2 导入，流程与 TTS 模型一致
/// - 音频先经 Android 原生解码器转成 16kHz 单声道 WAV，再喂给识别器
class AsrRecognizer {
  AsrRecognizer._();

  static final AsrRecognizer instance = AsrRecognizer._();

  /// 推荐模型（int8 量化，中文效果最好，自带标点）
  static const String recommendedModel =
      'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17';

  /// 更轻的备选（约 74MB）
  static const String lightweightModel = 'sherpa-onnx-paraformer-zh-small-2024-03-09';

  static const String modelDownloadPage =
      'https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models';

  bool _bindingsReady = false;
  sherpa.OfflineRecognizer? _recognizer;
  String? _modelDir;
  String? _modelPath;
  String? _tokensPath;

  /// 是否已安装识别模型
  bool get isModelReady => _modelPath != null && _tokensPath != null;

  /// 当前模型所在目录
  String? get modelDir => _modelDir;

  /// 当前模型名（目录名）
  String get modelName {
    final dir = _modelDir;
    if (dir == null) return '';
    final parts = dir.split(Platform.pathSeparator);
    return parts.last;
  }

  /// 模型存放目录（统一数据根下的 sherpa/asr，可用 adb 直接推送）
  Future<Directory> modelRoot() async {
    final dir = AppPaths.sherpaAsrDir;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 扫描模型目录，找到可用的识别模型（*.onnx + tokens.txt）
  Future<String?> detectModel() async {
    final root = await modelRoot();
    // ignore: avoid_print
    print('[ASR] 扫描目录: ${root.path} 存在=${root.existsSync()}');
    if (!root.existsSync()) return null;

    final candidates = <Directory>[root];
    try {
      for (final entity in root.listSync()) {
        if (entity is Directory) candidates.add(entity);
      }
    } catch (e) {
      // ignore: avoid_print
      print('[ASR] 列举目录失败: $e');
      return null;
    }


    for (final dir in candidates) {
      final files = dir.listSync().whereType<File>().toList();
      final onnx =
          files.where((f) => f.path.toLowerCase().endsWith('.onnx')).toList();
      final tokens =
          files.where((f) => _baseName(f.path) == 'tokens.txt').toList();
      if (onnx.isEmpty || tokens.isEmpty) continue;

      final modelFile = onnx.firstWhere(
        (f) => !_baseName(f.path).contains('vocoder'),
        orElse: () => onnx.first,
      );
      // ignore: avoid_print
      print('[ASR] 找到模型: ');
      _modelDir = dir.path;
      _modelPath = modelFile.path;
      _tokensPath = tokens.first.path;
      return _modelDir;
    }

    _modelDir = null;
    _modelPath = null;
    _tokensPath = null;
    return null;
  }
  /// 导入模型压缩包（.tar.bz2），解压后自动识别
  Future<String?> importArchive(
    File archiveFile, {
    void Function(double)? onProgress,
  }) async {
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

  /// 识别一段音频，返回文本（失败返回 null）
  ///
  /// [audioPath] 可以是任意常见音频格式，内部会先解码成 16kHz 单声道 WAV。
  Future<String?> recognize(String audioPath) async {
    final wavPath = await PlatformBridge.decodeAudioToWav(audioPath);
    if (wavPath == null) return null;
    try {
      return await recognizeWav(wavPath);
    } finally {
      // 临时文件用完即删
      try {
        final f = File(wavPath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {
        // 忽略
      }
    }
  }

  /// 直接识别一个 WAV 文件
  Future<String?> recognizeWav(String wavPath) async {
    final recognizer = await _ensureRecognizer();
    if (recognizer == null) return null;

    final wave = sherpa.readWave(wavPath);
    if (wave.samples.isEmpty || wave.sampleRate <= 0) return null;

    final stream = recognizer.createStream();
    try {
      stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
      recognizer.decode(stream);
      return _cleanText(recognizer.getResult(stream).text);
    } finally {
      stream.free();
    }
  }

  /// 清理模型输出里的标记（如 <|zh|><|NEUTRAL|>）与多余空白
  static String _cleanText(String raw) {
    var text = raw.replaceAll(RegExp(r'<\|[^|]*\|>'), '');
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    text = text.replaceAll(RegExp(r'\n{2,}'), '\n');
    return text.trim();
  }

  Future<sherpa.OfflineRecognizer?> _ensureRecognizer() async {
    if (_recognizer != null) return _recognizer;
    if (_modelPath == null || _tokensPath == null) {
      await detectModel();
    }
    final model = _modelPath;
    final tokens = _tokensPath;
    if (model == null || tokens == null) return null;

    if (!_bindingsReady) {
      await sherpa.initBindingsAsync();
      _bindingsReady = true;
    }

    // SenseVoice 与 ParaFormer 是两种模型族，同一个模型文件不能同时挂两处。
    // 模型的**目录名**里带模型族名（sherpa-onnx-sense-voice-... / -paraformer-...），
    // 而模型文件名统一叫 model.onnx / model.int8.onnx，所以要看目录。
    final dirName = (_modelDir ?? '').toLowerCase();
    final isSenseVoice = dirName.contains('sense');
    try {
      final recognizer = sherpa.OfflineRecognizer(
        sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(
            senseVoice: sherpa.OfflineSenseVoiceModelConfig(
              model: isSenseVoice ? model : '',
              language: '',
              // 逆文本正规化：把「一万零八十六」转成「10086」
              useInverseTextNormalization: true,
            ),
            paraformer: sherpa.OfflineParaformerModelConfig(
              model: isSenseVoice ? '' : model,
            ),
            tokens: tokens,
            numThreads: 2,
            debug: false,
            provider: 'cpu',
          ),
        ),
      );
      _recognizer = recognizer;
      return recognizer;
    } catch (e) {
      return null;
    }
  }

  static String _baseName(String path) {
    final index = path.lastIndexOf(Platform.pathSeparator);
    return index >= 0 ? path.substring(index + 1) : path;
  }
}