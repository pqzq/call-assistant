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

  /// 启动前台保活服务：进程不被系统回收，无障碍服务授权不会掉
  static Future<bool> startKeepAlive() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('startKeepAlive');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 停止前台保活服务
  static Future<bool> stopKeepAlive() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('stopKeepAlive');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 申请通知权限（Android 13+ 才有前台服务通知，不授权也不影响服务运行）
  static Future<bool> requestNotificationPermission() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('requestNotificationPermission');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 把文件保存到系统「下载」目录，返回展示路径（失败返回 null）
  ///
  /// 用 MediaStore 写入，不需要任何存储权限；比系统「另存为」对话框可靠得多。
  static Future<String?> saveToDownloads(String name, List<int> bytes) async {
    try {
      final result = await _methodChannel.invokeMethod<String>(
        'saveToDownloads',
        <String, Object>{'name': name, 'bytes': Uint8List.fromList(bytes)},
      );
      return result;
    } catch (_) {
      return null;
    }
  }

  /// 选一个文件夹，返回真实文件系统路径（取消返回 null）
  ///
  /// 走系统 SAF（ACTION_OPEN_DOCUMENT_TREE）并在原生侧解析 documentId，
  /// 比 file_picker 在部分 ROM（MIUI/HyperOS）上返回的路径可靠。
  static Future<String?> pickDirectory() async {
    try {
      return await _methodChannel.invokeMethod<String>('pickDirectory');
    } catch (_) {
      return null;
    }
  }

  /// 是否已获得「所有文件访问权限」（Android 11+ 读取外部目录需要）
  static Future<bool> hasAllFilesAccess() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('hasAllFilesAccess');
      return result ?? true;
    } catch (_) {
      return true; // 老系统或通道不可用时按已授权处理
    }
  }

  /// 跳转到系统「所有文件访问权限」设置页
  static Future<bool> requestAllFilesAccess() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('requestAllFilesAccess');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 打开系统无障碍设置页
  static Future<bool> openAccessibilitySettings() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('openAccessibilitySettings');
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
