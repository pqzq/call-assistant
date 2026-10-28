import 'package:local_notifier/local_notifier.dart';

import '../widgets/app_toast.dart';
import 'call_state_watcher.dart';
import 'platform_bridge.dart';

/// 统一的通知入口
///
/// - **Android**：走原生 `notifyBroadcast`（状态栏通知，见 `MainActivity`）
/// - **Windows / macOS / Linux**：走 `local_notifier`
///
/// Windows 的 Toast 需要「开始菜单里有匹配 AUMID 的快捷方式」，
/// `local_notifier` 默认策略（`requireCreate`）会在首次 setup 时自动创建一个，
/// 所以首次运行可能会在开始菜单里看到「话务助手」—— 这是正常且必要的。
///
/// 所有调用都是「失败静默」：通知发不出去不该影响播报本身。
class AppNotifier {
  AppNotifier._();

  static bool _ready = false;

  /// 桌面端是否初始化成功（Android 恒为 false，但不影响 notify）
  static bool get ready => _ready;

  /// 初始化（`main` 里调一次）
  ///
  /// Android 不需要初始化，直接返回。
  static Future<void> setup() async {
    if (!PlatformBridge.isDesktop) return;
    try {
      await LocalNotifier.instance.setup(appName: '话务助手');
      _ready = true;
    } catch (_) {
      // 没有桌面环境 / 建不了快捷方式 → 通知不可用，但不影响其它功能
      _ready = false;
    }
  }

  /// 发一条通知
  ///
  /// **按平台只走一条通道**（以前是应用内 + 系统都发，一次播报看起来像两条）：
  /// - **桌面端（Windows 10/11）**：只发系统 Toast；系统通知不可用
  ///   （快捷方式建不起来等）才退回应用内浮层
  /// - **Android**：应用内浮层 + 状态栏通知 —— 这两条各有用途
  ///   （浮层不怕通知权限被拒，状态栏锁屏也能看到），但也同样只有一次播报
  static Future<void> notify({
    required String title,
    required String body,
  }) async {
    if (PlatformBridge.isDesktop) {
      if (!_ready) {
        _fallback(title, body);
        return;
      }
      try {
        // 固定 identifier：后来的覆盖前一条，不在通知中心堆积
        await LocalNotification(
          identifier: 'broadcast-status',
          title: title,
          body: body,
        ).show();
      } catch (_) {
        _fallback(title, body);
      }
      return;
    }
    // Android
    _fallback(title, body);
    await CallStateWatcher.notifyBroadcast(title: title, body: body);
  }

  /// 应用内浮层（全局 overlay，任何页面都看得到）
  static void _fallback(String title, String body) {
    AppToast.show(null, '$title · $body',
        duration: const Duration(milliseconds: 3200));
  }
}
