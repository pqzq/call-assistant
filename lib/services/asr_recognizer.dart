import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
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
  AsrModelFiles? _files;

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

  /// 上次扫描 / 初始化失败的原因（给用户看的，成功时为 null）
  String? _lastError;
  String? get lastError => _lastError;

  /// 从目录里已列出的**文件路径**判定架构与所需部件（纯函数，便于单测）
  ///
  /// 判定只看文件名特征：
  /// - `encoder` + `decoder` + `joiner` → **transducer**（zipformer 等）
  /// - `encoder` + `decoder` 且目录名含 `whisper` → **whisper**
  /// - 单个 `model*.onnx` + tokens → **sense-voice / paraformer**
  ///   （这两族的模型文件都叫 `model.int8.onnx`，从文件上分不开，只能看目录名）
  ///
  /// 返回 null 表示这个目录组不成可用模型。
  @visibleForTesting
  static AsrModelFiles? classifyFiles(List<String> paths, String dirPath) {
    final onnx = paths.where((p) => p.toLowerCase().endsWith('.onnx')).toList();
    // Whisper 的 token 文件名是 `<名字>-tokens.txt`，所以用 endsWith 而不是等值
    final tokens = paths
        .where((p) => _baseName(p).toLowerCase().endsWith('tokens.txt'))
        .toList();
    if (onnx.isEmpty || tokens.isEmpty) return null;

    String? single;
    String? encoder;
    String? decoder;
    String? joiner;
    for (final p in onnx) {
      final name = _baseName(p).toLowerCase();
      if (name.contains('vocoder')) continue;
      if (name.contains('joiner')) {
        joiner ??= p;
      } else if (name.contains('encoder') || name.contains('encode')) {
        encoder ??= p;
      } else if (name.contains('decoder') || name.contains('decode')) {
        decoder ??= p;
      } else {
        single ??= p;
      }
    }

    final dirName = dirPath.toLowerCase();
    final AsrArch arch;
    if (encoder != null && decoder != null && joiner != null) {
      arch = AsrArch.transducer;
    } else if (encoder != null &&
        decoder != null &&
        dirName.contains('whisper')) {
      arch = AsrArch.whisper;
    } else if (dirName.contains('sense')) {
      arch = AsrArch.senseVoice;
    } else {
      arch = AsrArch.paraformer;
    }

    final bool usable = switch (arch) {
      AsrArch.transducer => encoder != null && decoder != null && joiner != null,
      AsrArch.whisper => encoder != null && decoder != null,
      AsrArch.senseVoice || AsrArch.paraformer => single != null,
    };
    if (!usable) return null;

    return AsrModelFiles(
      arch: arch,
      model: single ?? '',
      encoder: encoder ?? '',
      decoder: decoder ?? '',
      joiner: joiner ?? '',
      tokens: tokens.first,
    );
  }

  /// 给用户看的「为什么这个目录不能用」（`classifyFiles` 返回 null 时）
  static String _reasonOf(List<String> paths) {
    final hasOnnx = paths.any((p) => p.toLowerCase().endsWith('.onnx'));
    final hasTokens =
        paths.any((p) => _baseName(p).toLowerCase().endsWith('tokens.txt'));
    if (!hasOnnx && !hasTokens) return '没有 .onnx 模型文件，也没有 tokens.txt';
    if (!hasOnnx) return '没有 .onnx 模型文件';
    if (!hasTokens) return '没有 tokens.txt（whisper 需要 *-tokens.txt）';
    return '缺少该架构必需的部件（transducer 需要 encoder + decoder + joiner）';
  }

  static String _dirNameOf(String path) {
    final parts = path.split(Platform.pathSeparator);
    return parts.isEmpty ? path : parts.last;
  }

  /// 扫描模型目录，找到可用的识别模型
  Future<String?> detectModel() async {
    final root = await modelRoot();
    if (!root.existsSync()) {
      _lastError = '模型目录不存在：${root.path}';
      return null;
    }

    final candidates = <Directory>[root];
    try {
      for (final entity in root.listSync()) {
        if (entity is Directory) candidates.add(entity);
      }
    } catch (e) {
      _lastError = '列举模型目录失败：$e';
      return null;
    }

    final reasons = <String>[];
    for (final dir in candidates) {
      List<String> paths;
      try {
        paths =
            dir.listSync().whereType<File>().map((f) => f.path).toList();
      } catch (e) {
        reasons.add('${_dirNameOf(dir.path)}：读取失败（$e）');
        continue;
      }
      if (paths.isEmpty) continue;

      final files = classifyFiles(paths, dir.path);
      if (files == null) {
        reasons.add('${_dirNameOf(dir.path)}：${_reasonOf(paths)}');
        continue;
      }

      _modelDir = dir.path;
      _files = files;
      _lastError = null;
      return _modelDir;
    }

    _modelDir = null;
    _files = null;
    _lastError = reasons.isEmpty
        ? '模型目录是空的（${root.path}）'
        : reasons.join('\n');
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
      // 别静默吞掉：架构 / 模型的 config 不对时就是这里抛异常，
      // 之前直接 return null，用户只看到「识别失败」毫无线索。
      _lastError = '识别器创建失败（${files.arch.name}）：$e';
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
class AsrModelFiles {
  const AsrModelFiles({
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
