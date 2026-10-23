import 'package:flutter/foundation.dart';

import 'package:file_picker/file_picker.dart';

import 'call_state_watcher.dart';

/// 平台能力抽象层
///
/// 把 Android 专属能力（无障碍通话检测、SAF 选目录、MediaCodec 解码、系统下载目录）
/// 收拢到这里，其它模块只面向本类编程：
/// - Android：委托给原生 MethodChannel
/// - Windows / macOS / Linux：给出降级实现（不支持就返回 null / false）
///
/// 这样 PC 端（播放端角色）不需要在业务代码里到处写平台判断。
class PlatformBridge {
  const PlatformBridge._();

  /// 是否是桌面平台
  static bool get isDesktop {
    final t = defaultTargetPlatform;
    return t == TargetPlatform.windows ||
        t == TargetPlatform.macOS ||
        t == TargetPlatform.linux;
  }

  /// 是否是 Android
  static bool get isAndroid => defaultTargetPlatform == TargetPlatform.android;

  /// 是否支持「拨号跳转」（打开系统拨号页）
  ///
  /// 桌面没有系统拨号能力，PC 端只能复制号码。
  static bool get canDial {
    final t = defaultTargetPlatform;
    return t == TargetPlatform.android || t == TargetPlatform.iOS;
  }

  /// 是否支持「通话接通检测」（无障碍服务）
  ///
  /// 只有 Android 有无障碍服务；桌面端不存在「拨号端」角色。
  static bool get canDetectCall => isAndroid;

  /// 通话检测是否可用（无障碍服务已开启）
  static Future<bool> isCallDetectionEnabled() async {
    if (!canDetectCall) return false;
    return CallStateWatcher.isEnabled();
  }

  /// 打开系统无障碍设置页（桌面端不支持）
  static Future<bool> openAccessibilitySettings() async {
    if (!canDetectCall) return false;
    return CallStateWatcher.openAccessibilitySettings();
  }

  /// 前台保活（仅 Android 需要，桌面为 no-op）
  static Future<bool> startKeepAlive() async {
    if (!isAndroid) return false;
    return CallStateWatcher.startKeepAlive();
  }

  static Future<bool> stopKeepAlive() async {
    if (!isAndroid) return false;
    return CallStateWatcher.stopKeepAlive();
  }
  /// 选一个文件夹，返回真实路径
  static Future<String?> pickDirectory() async {
    if (isAndroid) {
      // Android 用 SAF 自己解析 documentId（各 ROM 返回的路径不一致）
      return CallStateWatcher.pickDirectory();
    }
    try {
      return await FilePicker.platform.getDirectoryPath(dialogTitle: '选择文件夹');
    } catch (_) {
      return null;
    }
  }

  /// 保存文件，返回展示用的路径（失败返回 null）
  static Future<String?> saveFile(String name, List<int> bytes) async {
    if (isAndroid) {
      // Android 用 MediaStore 直接写进系统「下载」目录
      return CallStateWatcher.saveToDownloads(name, bytes);
    }
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '保存文件',
        fileName: name,
        bytes: Uint8List.fromList(bytes),
      );
      return path;
    } catch (_) {
      return null;
    }
  }

  /// 把音频解码成 16kHz 单声道 WAV（供离线识别）
  ///
  /// Android 用原生 MediaCodec；桌面端暂未实现，返回 null（识别功能不可用）。
  static Future<String?> decodeAudioToWav(String path) async {
    if (!isAndroid) return null;
    return CallStateWatcher.decodeAudioToWav(path);
  }

  /// 音频解码是否可用
  static bool get canDecodeAudio => isAndroid;
}