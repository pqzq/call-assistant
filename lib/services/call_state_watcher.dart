import 'package:flutter/services.dart';

/// 一次通话状态变化
class CallStateEvent {
  const CallStateEvent({
    required this.connected,
    required this.detail,
    required this.packageName,
    required this.timestamp,
  });

  /// true = 对方已接通；false = 通话结束/服务断开
  final bool connected;

  /// 判断依据，例如 "00:05" / "通话中"
  final String detail;

  final String packageName;

  final DateTime timestamp;

  /// 通话时长（从 detail 里的计时器解析），解析不到返回 null
  Duration? get duration {
    final match = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(detail);
    if (match == null) return null;
    final minutes = int.tryParse(match.group(1)!) ?? 0;
    final seconds = int.tryParse(match.group(2)!) ?? 0;
    return Duration(minutes: minutes, seconds: seconds);
  }

  static CallStateEvent? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final connected = raw['connected'];
    if (connected is! bool) return null;
    final ts = raw['timestamp'];
    return CallStateEvent(
      connected: connected,
      detail: (raw['detail'] as String?) ?? '',
      packageName: (raw['package'] as String?) ?? '',
      timestamp: ts is int ? DateTime.fromMillisecondsSinceEpoch(ts) : DateTime.now(),
    );
  }
}

/// 与 Android 无障碍通话检测服务通信
class CallStateWatcher {
  const CallStateWatcher._();

  static const EventChannel _eventChannel = EventChannel('call_assistant/call_state');
  static const MethodChannel _methodChannel = MethodChannel('call_assistant/bridge');

  /// 通话状态流；平台未实现时静默结束（不抛异常，保证测试与降级可用）
  static Stream<CallStateEvent> stream() {
    try {
      return _eventChannel
          .receiveBroadcastStream()
          .map<CallStateEvent?>(CallStateEvent.fromMap)
          .where((CallStateEvent? event) => event != null)
          .cast<CallStateEvent>()
          .handleError((Object _) {});
    } catch (_) {
      return const Stream<CallStateEvent>.empty();
    }
  }

  /// 通话检测无障碍服务是否已开启
  static Future<bool> isEnabled() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('isAccessibilityEnabled');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 设备机型（用作默认设备名），取不到时返回空串
  static Future<String> deviceModel() async {
    try {
      final result = await _methodChannel.invokeMethod<String>('deviceModel');
      return (result ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  /// 跳转系统无障碍设置页
  static Future<void> openSettings() async {
    try {
      await _methodChannel.invokeMethod<bool>('openAccessibilitySettings');
    } catch (_) {
      // 平台不支持时忽略
    }
  }
}
