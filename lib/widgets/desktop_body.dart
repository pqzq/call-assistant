import 'package:flutter/material.dart';

import '../services/platform_bridge.dart';

/// 桌面端的内容限宽容器
///
/// 手机布局在宽屏上会被拉得很散，这里把**内容区**限制在固定宽度并居中，
/// 但**不限制 AppBar**（标题栏仍然通栏，更像桌面应用）。
/// 桌面端之外直接透传，不影响手机显示。
class DesktopBody extends StatelessWidget {
  const DesktopBody({super.key, required this.child, this.topAligned = true});

  final Widget child;

  /// true 时贴顶（配合 ListView 滚动），false 时居中
  final bool topAligned;

  /// 桌面端内容最大宽度
  static const double maxWidth = 820;

  @override
  Widget build(BuildContext context) {
    if (!PlatformBridge.isDesktop) return child;
    return ColoredBox(
      // 先把背景铺满，避免窗口两侧露出黑块
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Align(
        alignment: topAligned ? Alignment.topCenter : Alignment.center,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      ),
    );
  }
}