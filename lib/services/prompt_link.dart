import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/active_lead.dart';
import 'asr_recognizer.dart';
import 'call_log_store.dart';
import 'call_state_watcher.dart';
import 'platform_bridge.dart';
import 'lan_link.dart';
import 'avatar_renderer.dart';
import 'live2d_service.dart';
import 'tts_synthesizer.dart';

/// 数字人/联动状态
enum AvatarStatus {
  disabled,
  ready,
  armed,
  speaking,
  error;

  String get label {
    switch (this) {
      case AvatarStatus.disabled:
        return '数字人未启用';
      case AvatarStatus.ready:
        return '待拨号';
      case AvatarStatus.armed:
        return '等待接通';
      case AvatarStatus.speaking:
        return '播报中';
      case AvatarStatus.error:
        return '异常';
    }
  }
}

/// 联动日志
class PromptLog {
  PromptLog(this.time, this.message, {this.important = false});

  final DateTime time;
  final String message;
  final bool important;

  String get timeText =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
}

/// 双机联动：A 手机检测到通话接通 -> 局域网通知 B 手机朗读开场白
class PromptLink extends ChangeNotifier {
  PromptLink._();

  static final PromptLink instance = PromptLink._();

  static const String _kDeviceId = 'prompt_device_id';
  static const String _kDeviceName = 'prompt_device_name';
  static const String _kScript = 'prompt_script';
  static const String _kAutoTrigger = 'prompt_auto_trigger';
  static const String _kAsPlayer = 'prompt_as_player';
  static const String _kRate = 'prompt_rate';
  static const String _kAudioPath = 'prompt_audio_path';
  static const String _kAvatarEnabled = 'prompt_avatar_enabled';
  static const String _kAvatarModel = 'prompt_avatar_model';

  /// 数字人渲染后端（webview / native）
  static const String _kAvatarBackend = 'prompt_avatar_backend';

  /// 模型实际宽高比（由 WebView 端量出来并缓存，切换后端也能复用）
  static const String _kAvatarAspect = 'prompt_avatar_aspect';

  /// 上面那个比例对应的模型路径，换模型后作废
  static const String _kAvatarAspectModel = 'prompt_avatar_aspect_model';

  /// 模型放大系数（各模型 canvas 留白差异大，需要用户可调）
  static const String _kAvatarZoom = 'prompt_avatar_zoom';
  static const String _kAvatarPosX = 'prompt_avatar_pos_x';
  static const String _kAvatarPosY = 'prompt_avatar_pos_y';
  static const String _kBubbleCollapsed = 'prompt_bubble_collapsed';

  /// 浮动数字人默认位置（屏幕可用区域的归一化坐标）
  static const double defaultAvatarX = 0.82;
  static const double defaultAvatarY = 0.22;

  static const String defaultScript =
      '您好，我是本次项目的对接人，占用您一分钟时间，跟您同步一个事情，方便吗？';

  /// 演练/触发超时：拨号后 10 分钟内有效
  static const Duration _armTimeout = Duration(minutes: 10);

  final LanLink _link = LanLink();
  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _player = AudioPlayer();
  final Random _random = Random();

  String _deviceId = '';
  String _deviceName = '';
  String _script = defaultScript;
  double _rate = 0.5;
  bool _autoTrigger = false;

  /// 是否已订阅通话状态（避免重复订阅）
  bool _callStateSubscribed = false;

  /// 是否已与对端建立连接（由播放端主动发起）
  bool _peerConnected = false;
  String? _connectedPeerId;
  String? _connectedPeerName;

  /// 正在寻找拨号端
  bool _seeking = false;

  /// 单机自测：本机同时扮演拨号端与播放端（不用第二台手机就能测全链路）
  bool _singleDeviceTest = false;

  bool get singleDeviceTest => _singleDeviceTest;
  int _connectAttempts = 0;
  Timer? _queryTimer;

  /// 最近一次收到对端消息的时间（用于判断断开）
  DateTime? _lastPeerMessageAt;

  bool get peerConnected => _peerConnected;
  String? get connectedPeerName => _connectedPeerName;
  bool get seeking => _seeking;
  bool _asPlayer = false;
  bool _ttsReady = false;
  bool _initialized = false;
  bool _avatarEnabled = false;
  String _avatarModel = Live2dService.defaultModel;

  /// 当前模型的实际宽高比（宽/高）。0 表示还没量出来，
  /// 由 WebView 后端在页面加载后测量并写回（原生后端直接复用该值）。
  double _avatarModelAspect = 0;

  /// 上面那个比例是哪个模型量出来的
  String _avatarAspectModel = '';

  /// 模型放大系数（1.0 = 不额外放大）。默认 1.25 是为了抵消 canvas 留白。
  double _avatarModelZoom = 1.0;
  AvatarBackend _avatarBackend = kDefaultAvatarBackend;
  double _avatarPosX = defaultAvatarX;
  double _avatarPosY = defaultAvatarY;

  /// 是否正在播报（供状态条显示，避免用 mouth 高频刷新）
  bool _speaking = false;

  /// 当前跟进的客户（提词气泡数据）
  ActiveLead? _activeLead;
  int _stepIndex = 0;

  /// 提词气泡是否收起
  bool _bubbleCollapsed = false;

  /// 临时隐藏浮层（演示页）
  bool _suppressAvatar = false;

  bool _disposed = false;
  List<double>? _envelope;
  Timer? _mouthTimer;

  /// 开场白音频文件路径（优先于 TTS；很多定制 ROM 的系统 TTS 不对第三方开放）
  String? _audioPath;
  bool _accessibilityEnabled = false;
  bool _listening = false;
  String? _lastError;

  /// 已拨号、等待接通的状态
  bool _armed = false;
  DateTime? _armedAt;
  String _armedLabel = '';
  String _armedPhone = '';

  final List<PromptLog> _logs = <PromptLog>[];

  String get deviceId => _deviceId;
  String get deviceName => _deviceName;
  String get script => _script;
  double get rate => _rate;
  bool get autoTrigger => _autoTrigger;
  bool get asPlayer => _asPlayer;
  bool get ttsReady => _ttsReady;

  /// 数字人开关（关闭时不渲染、不驱动嘴型）
  bool get avatarEnabled => _avatarEnabled;

  /// 当前数字人模型（相对路径）
  String get avatarModel => _avatarModel;

  /// 浮动数字人位置（0~1，相对可用区域）
  double get avatarPosX => _avatarPosX;
  double get avatarPosY => _avatarPosY;

  /// 话术框是否收起（只收起话术框，数字人保持显示）
  bool get bubbleCollapsed => _bubbleCollapsed;

  /// 临时隐藏浮层（演示页等全屏场景使用，不持久化）
  bool get suppressAvatar => _suppressAvatar;

  void setSuppressAvatar(bool value) {
    if (_suppressAvatar == value) return;
    _suppressAvatar = value;
    notifyListeners();
  }

  /// 当前跟进的客户
  ActiveLead? get activeLead => _activeLead;

  /// 开场白按句拆分成的步骤（提词用）
  List<String> get scriptSteps => splitScript(_script);

  int get stepIndex => _stepIndex;

  String? get currentStep {
    final steps = scriptSteps;
    if (steps.isEmpty) return null;
    final index = _stepIndex.clamp(0, steps.length - 1);
    return steps[index];
  }

  /// 当前状态（供数字人状态条显示）
  AvatarStatus get avatarStatus {
    if (!_avatarEnabled) return AvatarStatus.disabled;
    if (_lastError != null) return AvatarStatus.error;
    if (_speaking) return AvatarStatus.speaking;
    if (_armed) return AvatarStatus.armed;
    return AvatarStatus.ready;
  }

  /// 估算一次播报的时长（演示页按它推进字幕）
  Duration get estimatedSpeakDuration {
    final envelope = _envelope;
    if (envelope != null && envelope.isNotEmpty) {
      return Duration(milliseconds: envelope.length * 50);
    }
    final length = _script.trim().length;
    return Duration(milliseconds: (length * 170).clamp(1200, 60000));
  }

  /// 把话术按中文标点拆成若干步（提词器用）
  static List<String> splitScript(String script) {
    final text = script.replaceAll('\r\n', '\n').trim();
    if (text.isEmpty) return const <String>[];
    final parts = <String>[];
    final buffer = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      buffer.write(char);
      final isBreak = char == '。' || char == '！' || char == '？' || char == '\n' || char == '；';
      if (isBreak) {
        final piece = buffer.toString().trim();
        if (piece.isNotEmpty) parts.add(piece);
        buffer.clear();
      }
    }
    final rest = buffer.toString().trim();
    if (rest.isNotEmpty) parts.add(rest);
    return parts;
  }

  void selectStep(int index) {
    final steps = scriptSteps;
    if (steps.isEmpty) return;
    final next = index.clamp(0, steps.length - 1);
    if (next == _stepIndex) return;
    _stepIndex = next;
    notifyListeners();
  }

  void nextStep() => selectStep(_stepIndex + 1);

  void previousStep() => selectStep(_stepIndex - 1);

  Future<void> setBubbleCollapsed(bool value) async {
    if (_bubbleCollapsed == value) return;
    _bubbleCollapsed = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kBubbleCollapsed, value);
    } catch (_) {
      // 忽略
    }
  }

  /// 拨号/切换行时设置当前客户，同时把话术步骤归零
  Future<void> setActiveLead(ActiveLead lead) async {
    _activeLead = lead;
    _stepIndex = 0;
    notifyListeners();
    // 记录本次拨打时间
    if (lead.phone != null) {
      await CallLogStore.recordCall(lead.phone!);
    }
  }

  void clearActiveLead() {
    _activeLead = null;
    _stepIndex = 0;
    notifyListeners();
  }

  /// 0~1 的嘴型幅度，Live2D 组件监听它
  final ValueNotifier<double> mouth = ValueNotifier<double>(0);

  bool get avatarSpeaking => mouth.value > 0.01;

  String? get audioPath => _audioPath;
  bool get hasAudio => _audioPath != null && File(_audioPath!).existsSync();
  String get audioFileName {
    final path = _audioPath;
    if (path == null) return '';
    return path.split(Platform.pathSeparator).last;
  }
  bool get accessibilityEnabled => _accessibilityEnabled;
  bool get listening => _listening;
  bool get armed => _armed;
  String get armedLabel => _armedLabel;
  String get armedPhone => _armedPhone;
  String? get lastError => _lastError;
  List<PromptLog> get logs => List<PromptLog>.unmodifiable(_logs.reversed.toList());
  List<LanPeer> get peers => _link.peers;
  bool get hasPeer => _link.peers.isNotEmpty;

  /// 应用启动时调用一次
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // 检测是否已安装语音识别模型（支持手动把模型目录推入）
    unawaited(() async {
      await AsrRecognizer.instance.detectModel();
      notifyListeners();
    }());

    final prefs = await SharedPreferences.getInstance();
    _deviceId = prefs.getString(_kDeviceId) ?? _newDeviceId();
    await prefs.setString(_kDeviceId, _deviceId);
    _link.localDeviceId = _deviceId;

    var name = prefs.getString(_kDeviceName) ?? '';
    // Platform.localHostname 在 Android 上恒为 localhost，改用机型名
    if (name.isEmpty || name == 'localhost') {
      final model = await CallStateWatcher.deviceModel();
      name = model.isEmpty ? '设备 ${_deviceId.substring(0, 4)}' : model;
      await prefs.setString(_kDeviceName, name);
    }
    _deviceName = name;
    _script = prefs.getString(_kScript) ?? defaultScript;
    _autoTrigger = prefs.getBool(_kAutoTrigger) ?? false;
    _asPlayer = prefs.getBool(_kAsPlayer) ?? false;
    // 桌面端（PC）没有系统拨号能力，只能当播放端
    if (PlatformBridge.isDesktop) {
      _autoTrigger = false;
      _asPlayer = true;
    }
    _rate = prefs.getDouble(_kRate) ?? 0.5;
    final savedAudio = prefs.getString(_kAudioPath);
    if (savedAudio != null && File(savedAudio).existsSync()) {
      // 旧版本存的是带时间戳的文件，迁移到固定的开场白文件后删掉旧的
      final fixed = await TtsSynthesizer.openingAudioFile();
      if (savedAudio != fixed.path) {
        try {
          await File(savedAudio).copy(fixed.path);
          final env = File('$savedAudio.env.json');
          if (env.existsSync()) await env.copy('${fixed.path}.env.json');
          await File(savedAudio).delete();
          if (env.existsSync()) await env.delete();
          _audioPath = fixed.path;
          await prefs.setString(_kAudioPath, fixed.path);
        } catch (_) {
          _audioPath = savedAudio;
        }
      } else {
        _audioPath = savedAudio;
      }
    } else {
      // 统一数据目录（AppPaths）迁移后旧绝对路径失效 → 回退到新根下的固定开场白文件
      final fixed = await TtsSynthesizer.openingAudioFile();
      if (fixed.existsSync()) {
        _audioPath = fixed.path;
        await prefs.setString(_kAudioPath, fixed.path);
      }
    }
    _avatarEnabled = prefs.getBool(_kAvatarEnabled) ?? false;
    _avatarModel = prefs.getString(_kAvatarModel) ?? Live2dService.defaultModel;
    _avatarBackend = AvatarBackend.fromName(prefs.getString(_kAvatarBackend));
    // 模型比例：只有和当前模型匹配才复用，换过模型就作废等重新量
    final savedAspectModel = prefs.getString(_kAvatarAspectModel) ?? '';
    final savedAspect = prefs.getDouble(_kAvatarAspect) ?? 0;
    if (savedAspectModel.isNotEmpty && savedAspectModel == _avatarModel) {
      _avatarModelAspect = savedAspect;
      _avatarAspectModel = savedAspectModel;
    }
    _avatarModelZoom = prefs.getDouble(_kAvatarZoom) ?? 1.0;
    _avatarPosX = prefs.getDouble(_kAvatarPosX) ?? defaultAvatarX;
    _avatarPosY = prefs.getDouble(_kAvatarPosY) ?? defaultAvatarY;
    _bubbleCollapsed = prefs.getBool(_kBubbleCollapsed) ?? false;
    notifyListeners();

    // 嘴型跟随音频播放位置
    _player.onPositionChanged.listen((position) {
      if (!_avatarEnabled) return;
      _updateMouthByPosition(position);
    });
    _player.onPlayerComplete.listen((_) => _stopMouth());

    await _initTts();
    await refreshAccessibility();
    await refreshTtsModel();

    // 按上次保存的配置决定要初始化哪些服务：
    // - 任一角色开启 -> 需要局域网通道（拨号端广播 / 播放端接收）
    // - 拨号端开启 -> 还需要订阅通话状态（无障碍检测接通）
    // - 数字人开启 -> 需要释放 Live2D 资源并启动本地服务，否则 WebView 会拿到 404
    if (_autoTrigger || _asPlayer) {
      await _startLink();
    }
    if (_autoTrigger) {
      CallStateWatcher.stream().listen(_onCallState);
      _callStateSubscribed = true;
      _log('已按配置启动拨号端服务（等待接通检测）');
      // 前台保活：避免进程被回收导致无障碍授权被系统移除
      await CallStateWatcher.requestNotificationPermission();
      await PlatformBridge.startKeepAlive();
    }
    if (_asPlayer) {
      _log('已按配置启动播放端服务（等待播报指令）');
    }
    if (_avatarEnabled) {
      _log('正在初始化数字人资源…');
      await Live2dService.instance.ensureStarted();
      _log('数字人资源已就绪');
    }
  }

  String _newDeviceId() {
    final random = Random();
    return List<String>.generate(6, (_) => random.nextInt(16).toRadixString(16)).join();
  }

  /// 系统 TTS 是否可用。
  ///
  /// 桌面端**完全禁用** flutter_tts：它的 Windows 实现直接调用 SAPI，
  /// 机器没装语音引擎时会在**原生层崩溃**（try/catch 拦不住，整个 App 闪退）。
  /// 桌面端统一走端侧合成（sherpa-onnx）。
  bool get _systemTtsAvailable => !PlatformBridge.isDesktop;

  Future<void> _initTts() async {
    if (!_systemTtsAvailable) {
      _ttsReady = false;
      return;
    }
    try {
      await _tts.setLanguage('zh-CN');
      await _tts.setSpeechRate(_rate);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      await _tts.awaitSpeakCompletion(true);
      // 很多定制 ROM（如 HyperOS）的系统 TTS 只对系统应用开放，这里做一次真实可用性校验
      final available = await _tts.isLanguageAvailable('zh-CN');
      _ttsReady = available == true || available == 1;
    } catch (_) {
      _ttsReady = false;
    }
    notifyListeners();
  }

  // ---------------- 端侧语音合成 ----------------

  bool get ttsModelReady => TtsSynthesizer.instance.isModelReady;
  String? get ttsModelDir => TtsSynthesizer.instance.modelDir;
  bool _synthesizing = false;
  bool get synthesizing => _synthesizing;

  Future<String> ttsModelRootPath() async => (await TtsSynthesizer.instance.modelRoot()).path;

  /// 扫描是否已安装端侧模型
  Future<void> refreshTtsModel() async {
    await TtsSynthesizer.instance.detectModel();
    notifyListeners();
  }

  /// 导入模型压缩包（.tar.bz2）
  Future<bool> importTtsModel() async {
    try {
      // 注意：FileType.any 不能同时传 allowedExtensions（file_picker 会抛异常）
      final result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (result == null || result.files.isEmpty) return false;
      final path = result.files.single.path;
      if (path == null) {
        _log('无法读取所选模型包');
        return false;
      }
      _log('正在解压模型包…', important: true);
      notifyListeners();
      final dir = await TtsSynthesizer.instance.importArchive(File(path));
      if (dir == null) {
        _log('模型包解压完成，但未识别到可用模型（需含 .onnx 与 tokens.txt）');
        return false;
      }
      _log('端侧模型已就绪：${dir.split(Platform.pathSeparator).where((e) => e.isNotEmpty).last}', important: true);
      notifyListeners();
      return true;
    } catch (e) {
      _log('导入模型失败：$e');
      return false;
    }
  }

  /// 用端侧模型把开场白文本合成成 wav，并设为播报音频
  Future<bool> synthesizeOpening() async {
    if (!ttsModelReady) {
      _log('尚未安装端侧模型，无法合成');
      return false;
    }
    if (_synthesizing) return false;
    _synthesizing = true;
    notifyListeners();
    final started = DateTime.now();
    try {
      final result = await TtsSynthesizer.instance.synthesize(text: _script, speed: _rate <= 0 ? 1.0 : _rate / 0.5);
      if (result == null) {
        _log('合成失败，请检查模型文件是否完整');
        return false;
      }
      final cost = DateTime.now().difference(started).inMilliseconds;
      await useAudioFile(result.wavPath);
      _log('语音合成完成（${cost}ms），已设为播报音频', important: true);
      return true;
    } catch (e) {
      _log('合成失败：$e');
      return false;
    } finally {
      _synthesizing = false;
      notifyListeners();
    }
  }

  /// 把指定音频文件设为播报音频
  ///
  /// 开场白音频**固定为一个文件**（documents/opening_audio.wav）：
  /// - 端侧合成直接写到它
  /// - 导入外部音频时复制过去覆盖
  /// 这里再做一次「搬移」，兼容旧版本留下的带时间戳的文件。
  Future<void> useAudioFile(String path) async {
    var target = path;
    final fixed = await TtsSynthesizer.openingAudioFile();
    if (path != fixed.path && File(path).existsSync()) {
      try {
        await File(path).copy(fixed.path);
        // 包络文件一起搬（嘴型数据）
        final env = File('$path.env.json');
        if (env.existsSync()) {
          await env.copy('${fixed.path}.env.json');
        }
        target = fixed.path;
        // 旧文件删掉，避免残留
        try {
          await File(path).delete();
          if (env.existsSync()) await env.delete();
        } catch (_) {
          // 忽略
        }
      } catch (_) {
        target = path;
      }
    }
    _audioPath = target;
    _envelope = await TtsSynthesizer.instance.loadEnvelope(target);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAudioPath, target);
    notifyListeners();
  }

  // ---------------- 数字人 ----------------

  /// 可用模型列表（含内置样例）
  Future<List<String>> availableAvatarModels() async {
    if (await Live2dService.instance.ensureStarted() == null) return <String>[];
    return Live2dService.instance.listModels();
  }

  Future<void> setAvatarEnabled(bool value) async {
    _avatarEnabled = value;
    if (!value) _stopMouth();
    notifyListeners();
    if (value) await Live2dService.instance.ensureStarted();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAvatarEnabled, value);
    _log(value ? '数字人已开启' : '数字人已关闭');
  }

  Future<void> setAvatarModel(String model) async {
    if (model.isEmpty || model == _avatarModel) return;
    _avatarModel = model;
    // 换了模型，之前量出来的宽高比不再有效
    _avatarModelAspect = 0;
    _avatarAspectModel = '';
    // 本体边界同样失效：它是相对上一个模型的 canvas 算的，留着会让
    // 原生侧按错误的比例缩放（实测 mao 会小好几倍）
    _avatarModelBounds = const <double>[];
    _avatarBoundsModel = '';
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAvatarModel, model);
    _log('数字人模型：$model');
  }

  /// 当前模型的实际宽高比（宽/高）。0 表示还没测出来，调用方应回退到默认比例。
  ///
  /// 由 WebView 后端在加载完成后用 `model.getLocalBounds()` 量出并写回；
  /// 原生后端直接复用这个缓存值（它本身是「填满高度」适配，
  /// 容器宽度一匹配，模型自然填满）。
  double get avatarModelAspect => _avatarModelAspect;

  /// 模型放大系数（1.0 = 不额外放大）
  ///
  /// 各模型 canvas 四周留白差异很大，固定值总会出现「有的显得太小、有的被裁」，
  /// 所以开放给用户调（设置里「模型大小」滑杆），调完持久化。
  double get avatarModelZoom => _avatarModelZoom;

  /// [persist] 为 false 时只更新内存并通知（滑杆拖动过程用），
  /// 松手（onChangeEnd）再调一次带 persist 的落盘，避免每帧写磁盘。
  /// 贴边紧凑模式：模型在渲染视图内部缩小（不重建视图）
  ///
  /// 由浮窗在贴边/恢复时设置，通过 [notifyListeners] 通知 renderer ——
  /// 不能只依赖 widget 的 didUpdateWidget（浮窗裁剪会改变 widget 树结构，
  /// 子组件不一定收到更新，结果就是贴边时模型不缩放）。
  bool _avatarCompact = false;

  /// 紧凑模式下模型贴向哪一侧（`right` = 靠右）
  String _avatarCompactSide = 'right';

  /// 紧凑模式的目标尺寸（逻辑像素）
  double _avatarCompactWidth = 0;
  double _avatarCompactHeight = 0;

  /// 是否处于贴边紧凑模式
  bool get avatarCompact => _avatarCompact;

  /// 紧凑模式的对齐侧
  String get avatarCompactSide => _avatarCompactSide;

  /// 紧凑模式的目标宽度
  double get avatarCompactWidth => _avatarCompactWidth;

  /// 紧凑模式的目标高度
  double get avatarCompactHeight => _avatarCompactHeight;

  /// 设置贴边紧凑模式
  void setAvatarCompact(
    bool enabled, {
    String side = 'right',
    double width = 0,
    double height = 0,
  }) {
    if (_avatarCompact == enabled &&
        _avatarCompactSide == side &&
        (_avatarCompactWidth - width).abs() < 0.5 &&
        (_avatarCompactHeight - height).abs() < 0.5) {
      return;
    }
    _avatarCompact = enabled;
    _avatarCompactSide = side;
    _avatarCompactWidth = width;
    _avatarCompactHeight = height;
    notifyListeners();
  }

  Future<void> setAvatarModelZoom(double zoom, {bool persist = true}) async {
    final v = zoom.clamp(0.8, 1.8).toDouble();
    if ((_avatarModelZoom - v).abs() < 0.001) return;
    _avatarModelZoom = v;
    notifyListeners();
    if (!persist) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kAvatarZoom, v);
    } catch (_) {
      // 忽略
    }
  }
  /// 记录 WebView 量到的模型宽高比
  /// 角色**本体**在 canvas 里的归一化矩形（中心x, 中心y, 宽, 高）
  ///
  /// 由 WebView 侧用 `model.getLocalBounds()` 量出。原生后端没有等价 API，
  /// 只能靠这个矩形才能按**角色本体**（而不是含大量留白的 canvas）对齐。
  /// 4 个分量都为空表示还没量到，原生侧会退化成按 canvas 适配。
  List<double> _avatarModelBounds = const <double>[];

  /// 上面这份矩形是**哪个模型**量出来的
  ///
  /// ⚠️ 必须绑定模型：归一化矩形是相对**该模型的 canvas** 算的，不同模型
  /// canvas 尺寸差很多（mao 就比 haru 大得多）。拿上一个模型的比例去给
  /// 新模型算缩放，会差好几倍 —— 表现就是「mao 在原生下小了几倍」。
  String _avatarBoundsModel = '';

  /// 角色本体在 canvas 里的归一化矩形（空列表 = 尚未量到 / 不属于当前模型）
  List<double> get avatarModelBounds =>
      _avatarBoundsModel == _avatarModel ? _avatarModelBounds : const <double>[];

  /// 记录角色本体在 canvas 里的归一化矩形（记在**当前模型**名下）
  void setAvatarModelBounds(List<double> bounds) {
    if (bounds.length != 4) return;
    final sameModel = _avatarBoundsModel == _avatarModel;
    if (sameModel && _avatarModelBounds.length == 4) {
      var same = true;
      for (var i = 0; i < 4; i++) {
        if ((_avatarModelBounds[i] - bounds[i]).abs() > 0.002) {
          same = false;
          break;
        }
      }
      if (same) return;
    }
    _avatarModelBounds = List<double>.from(bounds);
    _avatarBoundsModel = _avatarModel;
    notifyListeners();
  }

  Future<void> setAvatarModelAspect(double aspect) async {
    if (aspect <= 0.02 || aspect > 8) return;
    // 同一模型、比例几乎没变就不重复通知
    if (_avatarAspectModel == _avatarModel &&
        (_avatarModelAspect - aspect).abs() < 0.01) {
      return;
    }
    _avatarModelAspect = aspect;
    _avatarAspectModel = _avatarModel;
    _log('模型比例：${aspect.toStringAsFixed(3)}（宽/高）');
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kAvatarAspect, aspect);
      await prefs.setString(_kAvatarAspectModel, _avatarModel);
    } catch (_) {
      // 忽略：量出来只是用来调宽高，存不下也能用
    }
  }

  /// 保存浮动数字人的位置（0~1 归一化），拖动结束时调用
  Future<void> setAvatarPosition(double x, double y) async {
    _avatarPosX = x.clamp(0.0, 1.0);
    _avatarPosY = y.clamp(0.0, 1.0);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kAvatarPosX, _avatarPosX);
      await prefs.setDouble(_kAvatarPosY, _avatarPosY);
    } catch (_) {
      // 忽略
    }
  }

  /// 位置复位到默认（右上）
  Future<void> resetAvatarPosition() async {
    await setAvatarPosition(defaultAvatarX, defaultAvatarY);
    notifyListeners();
    _log('数字人位置已复位');
  }

  /// 导入用户自备模型（zip 内含 *.model3.json）
  Future<bool> importAvatarModel() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (result == null || result.files.isEmpty) return false;
      final picked = result.files.single.path;
      if (picked == null) {
        _log('无法读取所选模型包');
        return false;
      }
      _log('正在导入数字人模型…', important: true);
      notifyListeners();
      final model = await Live2dService.instance.importModelArchive(File(picked));
      if (model == null) {
        _log('导入失败：压缩包里没有 .model3.json');
        return false;
      }
      await setAvatarModel(model);
      _log('数字人模型已导入：$model', important: true);
      return true;
    } catch (e) {
      _log('导入数字人模型失败：$e');
      return false;
    }
  }

  /// 从文件夹导入数字人模型（递归找 .model3.json 并复制整个模型目录）
  Future<bool> importAvatarModelFromFolder() async {
    try {
      // Android 11+ 分区存储：没有「所有文件访问权限」就读不了用户选的目录，
      // 所以在打开目录选择器之前先检查并引导开启
      // Android 11+ 需要「所有文件访问权限」才能读取外部目录；
      // 桌面端没有这个限制
      if (PlatformBridge.isAndroid && !await CallStateWatcher.hasAllFilesAccess()) {
        _log('需要「所有文件访问权限」才能读取文件夹，正在跳转到系统设置…', important: true);
        await CallStateWatcher.requestAllFilesAccess();
        return false;
      }
      final dirPath = await PlatformBridge.pickDirectory();
      if (dirPath == null) return false;
      _log('正在从文件夹导入数字人模型…', important: true);
      notifyListeners();
      final model = await Live2dService.instance.importModelFolder(Directory(dirPath));
      if (model == null) {
        final reason = Live2dService.instance.lastImportError ?? '没有找到 .model3.json';
        _log('导入失败：$reason');
        return false;
      }
      await setAvatarModel(model);
      _log('数字人模型已从文件夹导入：$model', important: true);
      return true;
    } catch (e) {
      _log('从文件夹导入数字人模型失败：$e');
      return false;
    }
  }

  /// 识别模型是否已安装
  bool get asrModelReady => AsrRecognizer.instance.isModelReady;

  /// 当前识别模型名
  String get asrModelName => AsrRecognizer.instance.modelName;

  /// 导入语音识别模型（.tar.bz2）
  Future<bool> importAsrModel(File archiveFile) async {
    try {
      _log('正在导入语音识别模型…', important: true);
      notifyListeners();
      final dir = await AsrRecognizer.instance.importArchive(archiveFile);
      if (dir == null) {
        _log('导入失败：压缩包里没有找到模型文件（*.onnx + tokens.txt）');
        return false;
      }
      notifyListeners();
      _log('语音识别模型已导入：${AsrRecognizer.instance.modelName}', important: true);
      return true;
    } catch (e) {
      _log('导入语音识别模型失败：$e');
      return false;
    }
  }

  /// 把当前开场白音频识别成文本（失败返回 null）
  Future<String?> recognizeOpeningAudio() async {
    final path = _audioPath;
    if (path == null || !File(path).existsSync()) {
      _log('还没有设置开场白音频，无法识别');
      return null;
    }
    if (!AsrRecognizer.instance.isModelReady) {
      await AsrRecognizer.instance.detectModel();
      if (!AsrRecognizer.instance.isModelReady) {
        _log('还没有安装语音识别模型');
        return null;
      }
    }
    _log('正在识别开场白音频…', important: true);
    notifyListeners();
    try {
      final text = await AsrRecognizer.instance.recognize(path);
      if (text == null || text.isEmpty) {
        _log('识别失败：没有得到识别结果');
        return null;
      }
      _log('识别完成：$text', important: true);
      return text;
    } catch (e) {
      _log('识别失败：$e');
      return null;
    }
  }

  /// 最近一次模型导入失败的原因（界面提示用）
  String? get lastImportError => Live2dService.instance.lastImportError;

  /// 当前渲染后端
  AvatarBackend get avatarBackend => _avatarBackend;

  /// 切换渲染后端（webview / native），切换后数字人会重新加载
  Future<void> setAvatarBackend(AvatarBackend backend) async {
    if (_avatarBackend == backend) return;
    _avatarBackend = backend;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAvatarBackend, backend.name);
    } catch (_) {
      // 忽略
    }
    _log('数字人渲染后端已切换为：${backend.displayName}', important: true);
  }

  /// 移除用户导入的模型（内置模型不允许移除）
  ///
  /// 如果移除的是当前正在用的模型，会自动切回默认模型。
  Future<bool> deleteAvatarModel(String modelRelativePath) async {
    if (!Live2dService.isUserImported(modelRelativePath)) {
      _log('内置模型不能移除', important: true);
      return false;
    }
    await Live2dService.instance.deleteImportedModel(modelRelativePath);
    if (_avatarModel == modelRelativePath || _avatarModel.startsWith('$modelRelativePath/')) {
      await setAvatarModel(Live2dService.defaultModel);
    }
    notifyListeners();
    _log('已移除模型：$modelRelativePath', important: true);
    return true;
  }

  DateTime? _mouthClock;

  /// 播放音频时启动嘴型驱动（有包络用包络，没有就用程序化动画）
  void _startAudioMouth() {
    if (!_avatarEnabled) return;
    _mouthTimer?.cancel();
    _mouthClock = DateTime.now();
    if (!_speaking) {
      _speaking = true;
      notifyListeners();
    }
    final envelope = _envelope;
    _mouthTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      final clock = _mouthClock;
      if (clock == null) return;
      final elapsedMs = DateTime.now().difference(clock).inMilliseconds;
      final values = envelope;
      if (values != null && values.isNotEmpty) {
        final index = elapsedMs ~/ 50;
        if (index >= values.length) {
          _stopMouth();
          return;
        }
        mouth.value = values[index];
      } else {
        mouth.value = _proceduralMouth(elapsedMs);
      }
    });
  }

  /// 系统 TTS 朗读时没有音频位置，按文本长度估算时长做程序化口型
  void _startTtsMouth(String text) {
    if (!_avatarEnabled) return;
    _mouthTimer?.cancel();
    _mouthClock = DateTime.now();
    if (!_speaking) {
      _speaking = true;
      notifyListeners();
    }
    final estimated = (text.length * 170).clamp(1200, 60000);
    _mouthTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      final clock = _mouthClock;
      if (clock == null) return;
      final elapsedMs = DateTime.now().difference(clock).inMilliseconds;
      if (elapsedMs >= estimated) {
        _stopMouth();
        return;
      }
      mouth.value = _proceduralMouth(elapsedMs);
    });
  }

  double _proceduralMouth(int elapsedMs) {
    final t = elapsedMs / 1000.0;
    final wave = 0.5 + 0.5 * sin(t * 11.5);
    final jitter = 0.85 + 0.15 * _random.nextDouble();
    return (0.12 + 0.55 * wave * jitter).clamp(0.0, 1.0);
  }

  /// 播放位置事件：用来校正时钟漂移
  void _updateMouthByPosition(Duration position) {
    final envelope = _envelope;
    final clock = _mouthClock;
    if (envelope == null || envelope.isEmpty || clock == null) return;
    final expected = clock.add(position);
    final drift = DateTime.now().difference(expected).inMilliseconds;
    if (drift.abs() > 120) {
      _mouthClock = DateTime.now().subtract(position);
    }
  }

  void _stopMouth() {
    _mouthTimer?.cancel();
    _mouthTimer = null;
    _mouthClock = null;
    if (mouth.value != 0) mouth.value = 0;
    if (_speaking) {
      _speaking = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 选择开场白音频文件（复制到应用目录，避免被系统清理）
  /// 把**录音**得到的音频设为开场白
  ///
  /// 与「导入音频文件」走同一条落盘链路（都拷到固定的 opening_audio 位置），
  /// 所以播报、试听、识别都不需要区分音频来源。
  Future<bool> setOpeningAudioFromFile(String srcPath) async {
    try {
      final src = File(srcPath);
      if (!src.existsSync()) {
        _log('录音文件不存在');
        return false;
      }
      final target = await TtsSynthesizer.openingAudioFile();
      await target.parent.create(recursive: true);
      await src.copy(target.path);
      _audioPath = target.path;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAudioPath, target.path);
      _log('已用录音作为开场白音频', important: true);
      notifyListeners();
      return true;
    } catch (e) {
      _log('保存录音失败：$e');
      return false;
    }
  }

  Future<bool> pickAudio() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['mp3', 'wav', 'm4a', 'aac', 'ogg'],
      );
      if (result == null || result.files.isEmpty) return false;
      final picked = result.files.single;
      final srcPath = picked.path;
      if (srcPath == null) {
        _log('无法读取所选文件');
        return false;
      }
      // 固定存成同一个文件（覆盖替换），不再每次生成带时间戳的新文件
      final target = await TtsSynthesizer.openingAudioFile();
      await target.parent.create(recursive: true);
      await File(srcPath).copy(target.path);
      _audioPath = target.path;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAudioPath, target.path);
      _log('已选择开场白音频：${picked.name}', important: true);
      notifyListeners();
      return true;
    } catch (e) {
      _log('选择音频失败：$e');
      return false;
    }
  }

  Future<void> clearAudio() async {
    final path = _audioPath;
    _audioPath = null;
    try {
      if (path != null && File(path).existsSync()) {
        await File(path).delete();
        // 包络文件一起清掉
        final env = File('$path.env.json');
        if (env.existsSync()) await env.delete();
      }
    } catch (_) {
      // 忽略
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kAudioPath);
    } catch (_) {
      // 忽略
    }
    _log('已清除开场白音频');
    notifyListeners();
  }

  /// 播放已选的开场白音频
  Future<void> playAudio() async {
    final path = _audioPath;
    if (path == null) return;
    try {
      await _player.stop();
      await _player.play(DeviceFileSource(path));
      _startAudioMouth();
      _log('开始播放音频：$audioFileName');
    } catch (e) {
      _log('播放音频失败：$e');
      _stopMouth();
    }
  }

  Future<void> _startLink() async {
    final ok = await _link.start(_onLanMessage);
    _listening = ok;
    if (!ok) _lastError = '局域网通道启动失败（端口 ${LanLink.defaultPort} 被占用？）';
    notifyListeners();
    if (ok) {
      _announce();
      // 周期性宣告在线，方便两端互相发现（不刷日志，只有连接/断开才记录）
      Timer.periodic(const Duration(seconds: 5), (_) {
        _announce();
        _checkPeerTimeout();
      });
    }
  }

  /// 对端超过 15 秒没有消息 -> 视为断开，只在状态变化时记一条日志
  void _checkPeerTimeout() {
    final last = _lastPeerMessageAt;
    if (!_peerConnected || last == null) return;
    if (DateTime.now().difference(last).inSeconds < 15) return;
    final name = _connectedPeerName ?? '对端';
    _peerConnected = false;
    _connectedPeerId = null;
    _connectedPeerName = null;
    _log('$name 已断开连接');
    notifyListeners();
  }

  void _announce() {
    if (!_link.isRunning) return;
    _link.broadcast(LanMessage(
      type: LanMessageType.hello,
      deviceId: _deviceId,
      deviceName: _deviceName,
      role: _roleName,
    ));
  }

  String get _roleName {
    if (_asPlayer && _autoTrigger) return 'both';
    if (_asPlayer) return 'player';
    return 'dialer';
  }

  // ---------------- 设置 ----------------

  Future<void> setScript(String value) async {
    _script = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kScript, value);
  }

  Future<void> setRate(double value) async {
    _rate = value;
    notifyListeners();
    if (!_systemTtsAvailable) return;
    try {
      await _tts.setSpeechRate(value);
    } catch (_) {
      // 忽略
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kRate, value);
  }

  Future<void> setAutoTrigger(bool value) async {
    _autoTrigger = value;
    if (!value) _armed = false;
    notifyListeners();
    // 固化配置 + 按需启停服务
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoTrigger, value);
    await _syncServices();
    _announce();
    _log(value ? '已开启拨号端（接通后自动通知播放端）' : '已关闭拨号端');
  }

  Future<void> setAsPlayer(bool value) async {
    _asPlayer = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAsPlayer, value);
    await _syncServices();
    _announce();
    _log(value ? '已开启播放端（收到指令后朗读开场白）' : '已关闭播放端');
  }

  /// 根据当前角色配置启停后台服务（局域网通道 / 通话状态监听）
  Future<void> _syncServices() async {
    final needLink = _autoTrigger || _asPlayer;
    if (needLink && !_link.isRunning) {
      await _startLink();
    }
    if (_autoTrigger && !_callStateSubscribed) {
      CallStateWatcher.stream().listen(_onCallState);
      _callStateSubscribed = true;
    }
    if (!_autoTrigger && _callStateSubscribed) {
      _callStateSubscribed = false;
      _armed = false;
      await PlatformBridge.stopKeepAlive();
    }
  }

  Future<void> setDeviceName(String value) async {
    _deviceName = value.trim();
    notifyListeners();
    _announce();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDeviceName, _deviceName);
  }

  Future<bool> refreshAccessibility() async {
    _accessibilityEnabled = await PlatformBridge.isCallDetectionEnabled();
    notifyListeners();
    return _accessibilityEnabled;
  }

  // ---------------- 拨号端 ----------------

  /// 拨号时调用：进入"等待接通"状态
  void armAfterDial({required String rowLabel, required String phone}) {
    if (!_autoTrigger) return;
    _armed = true;
    _armedAt = DateTime.now();
    _armedLabel = rowLabel;
    _armedPhone = phone;
    _stepIndex = 0; // 新一通电话，话术从头开始
    _log('已拨号，等待接通：$rowLabel $phone');
    notifyListeners();
  }

  void _onCallState(CallStateEvent event) {
    if (!event.connected) {
      if (_armed) {
        _log('通话结束（未触发播报）');
        _armed = false;
        notifyListeners();
      }
      return;
    }

    if (!_armed) return;
    if (_armedAt != null && DateTime.now().difference(_armedAt!) > _armTimeout) {
      _log('等待超时，忽略本次接通');
      _armed = false;
      notifyListeners();
      return;
    }

    final label = _armedLabel;
    _armed = false;
    notifyListeners();

    _log('检测到接通（${event.detail}），通知播放端：$label', important: true);
    _broadcastAnswered(label);
  }

  void _broadcastAnswered(String label) {
    if (!_link.isRunning) {
      _log('局域网未就绪，无法通知播放端');
      return;
    }
    _link.broadcast(LanMessage(
      type: LanMessageType.answered,
      deviceId: _deviceId,
      deviceName: _deviceName,
      role: 'dialer',
      script: _script,
      rowLabel: label,
    ));
    _log('已广播播报指令');
    if (_asPlayer) {
      // 同一台手机也在播放角色时，本地兜底朗读
      speak(_script);
    }
  }

  /// 手动触发一次播报（测试用）
  Future<void> triggerManually() async {
    // 桌面端没有「另一台播放端」，点立即播报就本机播
    if (PlatformBridge.isDesktop) {
      _log('手动触发播报（本机）', important: true);
      await speak(_script);
      return;
    }
    _broadcastAnswered('手动触发');
    _log('手动触发播报', important: true);
  }

  /// 打断播报：停掉本机正在播放的内容，并通知播放端停止
  Future<void> interruptSpeaking() async {
    await stopSpeaking();
    if (_link.isRunning) {
      _link.broadcast(LanMessage(
        type: LanMessageType.stop,
        deviceId: _deviceId,
        deviceName: _deviceName,
        role: _roleName,
      ));
    }
    _log('已停止播报', important: true);
  }

  // ---------------- 播放端 ----------------

  Future<void> _onLanMessage(LanMessage message, LanPeer peer) async {
    final isSelf = message.deviceId == _deviceId;
    // 单机自测时允许处理自己的广播（模拟另一台手机）
    if (isSelf && !_singleDeviceTest) return;
    _lastPeerMessageAt = DateTime.now();
    // 单机自测：自己扮演拨号端
    final peerRole = isSelf ? 'dialer' : peer.role;

    switch (message.type) {
      case LanMessageType.query:
        // 播放端在找拨号端：拨号端回应自己的身份
        if (_autoTrigger && (!_asPlayer || _singleDeviceTest)) {
          _send(peer, LanMessageType.hello);
        }
        break;

      case LanMessageType.hello:
        // 拨号端的存在宣告（每 5 秒一次，不再刷日志）
        if (_asPlayer && !_peerConnected && (peerRole == 'dialer' || _singleDeviceTest)) {
          // 播放端主动发起连接
          _send(peer, LanMessageType.connect);
        }
        break;

      case LanMessageType.connect:
        // 播放端请求连接：拨号端确认
        if (_autoTrigger) {
          _send(peer, LanMessageType.connected);
          _markConnected(
            peer,
            isSelf ? '模拟拨号端已连接（本机自测）' : '播放端已连接：${peer.displayName}',
          );
        }
        break;

      case LanMessageType.connected:
        // 拨号端确认连接
        _markConnected(peer, '已连接拨号端：${peer.displayName}');
        break;

      case LanMessageType.answered:
        if (!_asPlayer) {
          _log('收到播报指令，但本机未开启播放端');
          return;
        }
        final text = message.script.trim().isEmpty ? _script : message.script;
        _log('收到播报指令（来自 ${peer.displayName}）：${message.rowLabel}', important: true);
        speak(text);
        break;

      case LanMessageType.stop:
        if (!_asPlayer) return;
        await stopSpeaking();
        _log('收到停止播报指令', important: true);
        break;

      default:
        break;
    }
  }

  void _send(LanPeer peer, String type) {
    _link.sendTo(
      LanMessage(
        type: type,
        deviceId: _deviceId,
        deviceName: _deviceName,
        role: _roleName,
      ),
      peer,
    );
  }

  void _markConnected(LanPeer peer, String log) {
    final already = _peerConnected && _connectedPeerId == peer.deviceId;
    _peerConnected = true;
    _connectedPeerId = peer.deviceId;
    _connectedPeerName = peer.displayName;
    if (!already) {
      _log(log, important: true);
    }
    notifyListeners();
  }

  /// 播放端：手动发起连接拨号端
  Future<void> connectToDialer() async {
    if (!_asPlayer) {
      _log('请先开启「播放端」');
      return;
    }
    _seeking = true;
    _connectAttempts = 0;
    notifyListeners();
    _log('正在寻找拨号端…');
    _queryTimer?.cancel();
    _queryTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!_seeking || _peerConnected) {
        timer.cancel();
        _seeking = false;
        notifyListeners();
        return;
      }
      _connectAttempts++;
      if (_connectAttempts > 15) {
        timer.cancel();
        _seeking = false;
        notifyListeners();
        _log('未找到拨号端，请确认两台手机在同一 Wi-Fi 且拨号端已开启');
        return;
      }
      _link.broadcast(LanMessage(
        type: LanMessageType.query,
        deviceId: _deviceId,
        deviceName: _deviceName,
        role: _roleName,
      ));
    });
  }

  /// 单机自测开关：本机同时扮演拨号端与播放端
  Future<void> setSingleDeviceTest(bool value) async {
    if (_singleDeviceTest == value) return;
    _singleDeviceTest = value;
    _link.acceptSelf = value;
    notifyListeners();
    _log(value ? '已开启单机自测（本机模拟拨号端）' : '已关闭单机自测');
  }

  /// 断开与拨号端的连接
  Future<void> disconnectPeer() async {
    _queryTimer?.cancel();
    _queryTimer = null;
    _seeking = false;
    if (_peerConnected) {
      _log('已断开拨号端连接');
    }
    _peerConnected = false;
    _connectedPeerId = null;
    _connectedPeerName = null;
    notifyListeners();
  }

  /// 播放开场白：优先用音频文件，其次系统 TTS
  Future<void> speak(String text) async {
    // 先打断正在播的内容（避免叠音，也实现「打断播报」）
    await stopSpeaking();
    if (hasAudio) {
      await playAudio();
      return;
    }
    final content = text.trim();
    if (content.isEmpty) return;

    // 桌面端：系统 TTS（flutter_tts）在 Windows 上直接调用 SAPI，
    // 机器没装语音引擎时会在原生层崩溃（整个 App 闪退），所以只走端侧合成。
    if (PlatformBridge.isDesktop) {
      await _speakByLocalSynth(content);
      return;
    }

    if (!_ttsReady) {
      await _initTts();
      if (!_ttsReady) {
        _log('本机 TTS 不可用，无法朗读');
        return;
      }
    }
    if (!_systemTtsAvailable) return;
    try {
      await _tts.stop();
      await _tts.speak(content);
      _startTtsMouth(content);
      _log('开始朗读：${content.length > 18 ? '${content.substring(0, 18)}…' : content}');
    } catch (e) {
      _log('朗读失败：$e');
      _stopMouth();
    }
  }

  /// 桌面端播报：用端侧模型合成后播放（不依赖系统语音引擎）
  Future<void> _speakByLocalSynth(String content) async {
    if (!ttsModelReady) {
      _log('桌面端需要端侧语音模型才能朗读（请先导入 TTS 模型）');
      return;
    }
    try {
      final result = await TtsSynthesizer.instance.synthesize(
        text: content,
        speed: _rate <= 0 ? 1.0 : _rate / 0.5,
      );
      if (result == null) {
        _log('端侧合成失败，请检查模型文件是否完整');
        return;
      }
      await _playLocalWav(result);
    } catch (e) {
      _log('端侧合成失败：$e');
    }
  }

  /// 播放端侧合成的 wav，并按包络驱动嘴型（复用音频播放的嘴型逻辑）
  Future<void> _playLocalWav(SynthesisResult result) async {
    _envelope = result.envelope;
    try {
      await _player.stop();
      await _player.play(DeviceFileSource(result.wavPath));
      _startAudioMouth();
      _log('开始朗读（端侧合成 ${result.duration.inMilliseconds}ms）');
    } catch (e) {
      _log('播放失败：$e');
    }
  }

  Future<void> stopSpeaking() async {
    _stopMouth();
    if (_systemTtsAvailable) {
      try {
        await _tts.stop();
      } catch (_) {
        // 忽略
      }
    }
    try {
      await _player.stop();
    } catch (_) {
      // 忽略
    }
  }

  // ---------------- 日志 ----------------

  void _log(String message, {bool important = false}) {
    _logs.add(PromptLog(DateTime.now(), message, important: important));
    if (_logs.length > 60) _logs.removeAt(0);
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _mouthTimer?.cancel();
    _link.close();
    if (_systemTtsAvailable) {
      _tts.stop();
    }
    _player.dispose();
    mouth.dispose();
    super.dispose();
  }
}
