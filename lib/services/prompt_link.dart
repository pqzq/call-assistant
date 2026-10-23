import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'call_state_watcher.dart';
import 'lan_link.dart';

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

  static const String defaultScript =
      '您好，我是本次项目的对接人，占用您一分钟时间，跟您同步一个事情，方便吗？';

  /// 演练/触发超时：拨号后 10 分钟内有效
  static const Duration _armTimeout = Duration(minutes: 10);

  final LanLink _link = LanLink();
  final FlutterTts _tts = FlutterTts();

  String _deviceId = '';
  String _deviceName = '';
  String _script = defaultScript;
  double _rate = 0.5;
  bool _autoTrigger = true;
  bool _asPlayer = true;
  bool _ttsReady = false;
  bool _initialized = false;
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
    _deviceName = prefs.getString(_kDeviceName) ?? Platform.localHostname;
    _script = prefs.getString(_kScript) ?? defaultScript;
    _autoTrigger = prefs.getBool(_kAutoTrigger) ?? true;
    _asPlayer = prefs.getBool(_kAsPlayer) ?? true;
    _rate = prefs.getDouble(_kRate) ?? 0.5;
    notifyListeners();

    await _initTts();
    await refreshAccessibility();
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
      _ttsReady = true;
    } catch (_) {
      _ttsReady = false;
    }
    notifyListeners();
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

  /// 朗读文本（播放端）
  Future<void> speak(String text) async {
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
      _log('开始朗读：${content.length > 18 ? '${content.substring(0, 18)}…' : content}');
    } catch (e) {
      _log('朗读失败：$e');
    }
  }

  Future<void> stopSpeaking() async {
    try {
      await _tts.stop();
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
    _link.close();
    _tts.stop();
    super.dispose();
  }
}
