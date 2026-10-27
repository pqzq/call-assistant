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
  _AsrFiles? _files;

  /// 是否已安装识别模型
  bool get isModelReady => _files != null;

  /// 当前模型的架构（未安装时为 null）
  AsrArch? get arch => _files?.arch;

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
      final entries = dir.listSync();
      final files = entries.whereType<File>().toList();
      final onnx =
          files.where((f) => f.path.toLowerCase().endsWith('.onnx')).toList();
      final tokens =
          files.where((f) => _baseName(f.path) == 'tokens.txt').toList();
      if (onnx.isEmpty || tokens.isEmpty) continue;

      // 按文件名把各架构需要的部件分出来。
      //
      // sense-voice / paraformer 都是单个 model*.onnx，**从文件上分不开**，
      // 只能看目录名；而 zipformer（transducer）和 whisper 有多文件特征：
      //   transformer: encoder + decoder + joiner
      //   whisper:     encoder + decoder
      File? single;
      File? encoder;
      File? decoder;
      File? joiner;
      for (final f in onnx) {
        final name = _baseName(f.path).toLowerCase();
        if (name.contains('vocoder')) continue;
        if (name.contains('joiner')) {
          joiner ??= f;
        } else if (name.contains('encoder') || name.contains('encode')) {
          encoder ??= f;
        } else if (name.contains('decoder') || name.contains('decode')) {
          decoder ??= f;
        } else {
          single ??= f;
        }
      }

      final dirName = dir.path.toLowerCase();
      final AsrArch modelArch;
      if (encoder != null && decoder != null && joiner != null) {
        modelArch = AsrArch.transducer;
      } else if (encoder != null &&
          decoder != null &&
          dirName.contains('whisper')) {
        modelArch = AsrArch.whisper;
      } else if (dirName.contains('sense')) {
        modelArch = AsrArch.senseVoice;
      } else {
        modelArch = AsrArch.paraformer;
      }

      // 该架构必需的部件必须齐，否则跳过这个目录
      final bool usable = switch (modelArch) {
        AsrArch.transducer =>
          encoder != null && decoder != null && joiner != null,
        AsrArch.whisper => encoder != null && decoder != null,
        AsrArch.senseVoice || AsrArch.paraformer => single != null,
      };
      if (!usable) continue;

      _modelDir = dir.path;
      _files = _AsrFiles(
        arch: modelArch,
        model: single?.path ?? '',
        encoder: encoder?.path ?? '',
        decoder: decoder?.path ?? '',
        joiner: joiner?.path ?? '',
        tokens: tokens.first.path,
      );
      // ignore: avoid_print
      print('[ASR] 找到模型: $modelArch');
      return _modelDir;
    }

    _modelDir = null;
    _files = null;
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
    if (_files == null) {
      await detectModel();
    }
    final files = _files;
    if (files == null) return null;

    if (!_bindingsReady) {
      await sherpa.initBindingsAsync();
      _bindingsReady = true;
    }

    // 按识别到的架构填对应 config。
    //
    // 之前只判断「目录名含 sense」，其他一律按 paraformer ——
    // zipformer（transducer）和 whisper 的模型即使导入了也用不起来。
    // 不设 modelType：sherpa 按「填了哪个 config」自己判断，写字符串反而容易错。
    final sherpa.OfflineModelConfig modelConfig;
    switch (files.arch) {
      case AsrArch.transducer:
        modelConfig = sherpa.OfflineModelConfig(
          transducer: sherpa.OfflineTransducerModelConfig(
            encoder: files.encoder,
            decoder: files.decoder,
            joiner: files.joiner,
          ),
          tokens: files.tokens,
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        );
      case AsrArch.whisper:
        modelConfig = sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder: files.encoder,
            decoder: files.decoder,
            language: '', // 空 = 自动检测
            task: 'transcribe',
          ),
          tokens: files.tokens,
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        );
      case AsrArch.senseVoice:
        modelConfig = sherpa.OfflineModelConfig(
          senseVoice: sherpa.OfflineSenseVoiceModelConfig(
            model: files.model,
            language: '',
            // 逆文本正规化：把「一万零八十六」转成「10086」
            useInverseTextNormalization: true,
          ),
          tokens: files.tokens,
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        );
      case AsrArch.paraformer:
        modelConfig = sherpa.OfflineModelConfig(
          paraformer: sherpa.OfflineParaformerModelConfig(model: files.model),
          tokens: files.tokens,
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        );
    }

    try {
      final recognizer = sherpa.OfflineRecognizer(
        sherpa.OfflineRecognizerConfig(model: modelConfig),
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

/// ASR 模型架构（按模型目录里的文件特征判定）
enum AsrArch {
  /// SenseVoice：单文件 + tokens（中英日韩粤自动检测）
  senseVoice,

  /// Paraformer：单文件 + tokens（中文，体积更小）
  paraformer,

  /// Transducer（zipformer 等）：encoder + decoder + joiner
  transducer,

  /// Whisper：encoder + decoder（多语种，代价是体积和速度）
  whisper,
}

/// 一个识别模型目录里识别出来的文件组合
class _AsrFiles {
  const _AsrFiles({
    required this.arch,
    required this.tokens,
    this.model = '',
    this.encoder = '',
    this.decoder = '',
    this.joiner = '',
  });

  final AsrArch arch;

  /// senseVoice / paraformer 的单文件模型
  final String model;

  /// transducer / whisper 的 encoder、decoder（transducer 另需 joiner）
  final String encoder;
  final String decoder;
  final String joiner;

  final String tokens;
}

/// 可下载的推荐 ASR 模型（直链，点了直接下 .tar.bz2）
class AsrModelOption {
  const AsrModelOption({
    required this.name,
    required this.languages,
    required this.note,
  });

  final String name;
  final String languages;
  final String note;

  /// 直链下载地址
  String get url =>
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$name.tar.bz2';
}

/// 推荐模型清单（与 README 的表格保持一致）
const List<AsrModelOption> kAsrModelOptions = <AsrModelOption>[
  AsrModelOption(
    name: 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17',
    languages: '中 / 英 / 日 / 韩 / 粤（自动检测）',
    note: '推荐：多语言 + 自带标点，不用手动选语言',
  ),
  AsrModelOption(
    name: 'sherpa-onnx-paraformer-zh-small-2024-03-09',
    languages: '中文',
    note: '轻量备选（约 74MB），中文短句识别快',
  ),
];
