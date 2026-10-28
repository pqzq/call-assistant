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
  /// 两条通道一起走：
  /// 1. **应用内全局提示**（`AppToast`，用全局 navigatorKey 的 overlay）——
  ///    不管在哪个页面都看得到，也不受系统通知权限/专注助手影响
  /// 2. **系统通知** —— Android 状态栏；**Windows 10/11 原生 Toast**
  ///    （macOS / Linux 不做，按需求只考虑 Win10/11）
  static Future<void> notify({
    required String title,
    required String body,
  }) async {
    // 应用内先出：系统通知可能被拒/被专注助手折叠，这条一定看得到
    AppToast.show(null, '$title · $body',
        duration: const Duration(milliseconds: 3200));

    if (PlatformBridge.isDesktop) {
      if (!_ready) return;
      try {
        await LocalNotification(title: title, body: body).show();
      } catch (_) {
        // 忽略
      }
      return;
    }
    await CallStateWatcher.notifyBroadcast(title: title, body: body);
  }
}
