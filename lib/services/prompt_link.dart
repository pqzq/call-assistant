import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/active_lead.dart';
import 'call_log_store.dart';
import 'call_state_watcher.dart';
import 'lan_link.dart';
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
  static const String _kAvatarPosX = 'prompt_avatar_pos_x';
  static const String _kAvatarPosY = 'prompt_avatar_pos_y';
  static const String _kCollapsed = 'prompt_avatar_collapsed';

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
  bool _autoTrigger = true;
  bool _asPlayer = true;
  bool _ttsReady = false;
  bool _initialized = false;
  bool _avatarEnabled = false;
  String _avatarModel = Live2dService.defaultModel;
  double _avatarPosX = defaultAvatarX;
  double _avatarPosY = defaultAvatarY;

  /// 是否正在播报（供状态条显示，避免用 mouth 高频刷新）
  bool _speaking = false;

  /// 当前跟进的客户（提词气泡数据）
  ActiveLead? _activeLead;
  int _stepIndex = 0;

  /// 提词气泡是否收起
  bool _collapsed = false;

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

  /// 提词气泡是否收起
  bool get collapsed => _collapsed;

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

  Future<void> setCollapsed(bool value) async {
    if (_collapsed == value) return;
    _collapsed = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kCollapsed, value);
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
    _autoTrigger = prefs.getBool(_kAutoTrigger) ?? true;
    _asPlayer = prefs.getBool(_kAsPlayer) ?? true;
    _rate = prefs.getDouble(_kRate) ?? 0.5;
    final savedAudio = prefs.getString(_kAudioPath);
    if (savedAudio != null && File(savedAudio).existsSync()) _audioPath = savedAudio;
    _avatarEnabled = prefs.getBool(_kAvatarEnabled) ?? false;
    _avatarModel = prefs.getString(_kAvatarModel) ?? Live2dService.defaultModel;
    _avatarPosX = prefs.getDouble(_kAvatarPosX) ?? defaultAvatarX;
    _avatarPosY = prefs.getDouble(_kAvatarPosY) ?? defaultAvatarY;
    _collapsed = prefs.getBool(_kCollapsed) ?? false;
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
    await _startLink();
    CallStateWatcher.stream().listen(_onCallState);
  }

  String _newDeviceId() {
    final random = Random();
    return List<String>.generate(6, (_) => random.nextInt(16).toRadixString(16)).join();
  }

  Future<void> _initTts() async {
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
  Future<void> useAudioFile(String path) async {
    _audioPath = path;
    _envelope = await TtsSynthesizer.instance.loadEnvelope(path);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAudioPath, path);
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
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAvatarModel, model);
    _log('数字人模型：$model');
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
      final dir = await getApplicationDocumentsDirectory();
      final dot = srcPath.lastIndexOf('.');
      final ext = dot >= 0 ? srcPath.substring(dot) : '.mp3';
      final target = File('${dir.path}/opening_${DateTime.now().millisecondsSinceEpoch}$ext');
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
      if (path != null && File(path).existsSync()) await File(path).delete();
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
      // 周期性宣告在线，方便两端互相发现
      Timer.periodic(const Duration(seconds: 5), (_) => _announce());
    }
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
    _announce();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoTrigger, value);
  }

  Future<void> setAsPlayer(bool value) async {
    _asPlayer = value;
    notifyListeners();
    _announce();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAsPlayer, value);
  }

  Future<void> setDeviceName(String value) async {
    _deviceName = value.trim();
    notifyListeners();
    _announce();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDeviceName, _deviceName);
  }

  Future<bool> refreshAccessibility() async {
    _accessibilityEnabled = await CallStateWatcher.isEnabled();
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
    _broadcastAnswered('手动触发');
    _log('手动触发播报', important: true);
  }

  // ---------------- 播放端 ----------------

  void _onLanMessage(LanMessage message, LanPeer peer) {
    if (message.deviceId == _deviceId) return;

    switch (message.type) {
      case LanMessageType.hello:
        _log('发现对端：${peer.displayName}（${peer.address.address}）');
        notifyListeners();
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
      default:
        break;
    }
  }

  /// 播放开场白：优先用音频文件，其次系统 TTS
  Future<void> speak(String text) async {
    if (hasAudio) {
      await playAudio();
      return;
    }
    final content = text.trim();
    if (content.isEmpty) return;
    if (!_ttsReady) {
      await _initTts();
      if (!_ttsReady) {
        _log('本机 TTS 不可用，无法朗读');
        return;
      }
    }
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

  Future<void> stopSpeaking() async {
    _stopMouth();
    try {
      await _tts.stop();
    } catch (_) {
      // 忽略
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
    _tts.stop();
    _player.dispose();
    mouth.dispose();
    super.dispose();
  }
}
