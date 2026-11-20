import 'package:material_ui/material_ui.dart';

/// 全局 Navigator 的 Key
///
/// `MaterialApp.builder` 返回的内容位于 **Navigator 之外**，所以桌面端分栏里的
/// 控件拿不到 Navigator / Overlay 祖先：
/// - `showModalBottomSheet` 会抛「找不到 Navigator」
/// - `Overlay.maybeOf` 返回 null，Toast 静默不显示
///
/// 这里的 Key 让这些组件可以拿到全局 NavigatorState。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// 取得当前可用的 NavigatorState（优先用 context 上的，回退到全局 key）
NavigatorState? resolveNavigator(BuildContext? context) {
  if (context != null) {
    final local = Navigator.maybeOf(context);
    if (local != null) return local;
  }
  return appNavigatorKey.currentState;
}

/// 取得当前可用的 Overlay（优先用 context 上的，回退到全局 Navigator 的 overlay）
OverlayState? resolveOverlay(BuildContext? context) {
  if (context != null) {
    final local = Overlay.maybeOf(context, rootOverlay: true);
    if (local != null) return local;
  }
  return appNavigatorKey.currentState?.overlay;
}