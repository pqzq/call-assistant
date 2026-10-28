import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 弧形操作栏里的一个动作
class ArcAction {
  const ArcAction({
    required this.icon,
    this.tooltip,
    this.onTap,
    this.enabled = true,
    this.isDragHandle = false,
    this.danger = false,
  });

  final IconData icon;
  final String? tooltip;
  final VoidCallback? onTap;
  final bool enabled;

  /// 拖动柄（用 pan 手势而不是 tap）
  final bool isDragHandle;

  /// 危险操作（关闭）—— 图标用红色
  final bool danger;
}

/// 月亮型（弧形）动作栏
///
/// 设计要点：
/// - **无背景**：只有图标，浮在页面上（图标带柔和投影，浅/深背景都能看清）
/// - **弧形排布**：图标沿一条凸向「角色」的弧线分布，整体轮廓像一弯月牙
/// - **大点击区**：每个图标 46×46（图标本身 27），比之前 32 的格子好按
///
/// 放在角色**左侧**时弧凸向右（贴着角色轮廓），放在右侧时凸向左。
class ArcActionBar extends StatelessWidget {
  const ArcActionBar({
    super.key,
    required this.height,
    required this.actions,
    this.flip = false,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onDragCancel,
    this.dragging = false,
  });

  /// 与角色同高
  final double height;

  final List<ArcAction> actions;

  /// 是否镜像（放在角色右侧时用）
  final bool flip;

  final VoidCallback? onDragStart;
  final void Function(DragUpdateDetails details)? onDragUpdate;
  final VoidCallback? onDragEnd;
  final VoidCallback? onDragCancel;

  /// 正在拖动（拖动柄高亮）
  final bool dragging;

  /// 图标点击区尺寸
  static const double tapSize = 42;

  /// 图标本身的尺寸
  static const double iconSize = 23;

  /// 整条操作栏的宽度（含图标外扩空间）
  static const double barWidth = 70;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) return const SizedBox(width: barWidth, height: 0);

    // 弧：半径按高度取值，图标越多角度铺得越开
    final radius = height * 0.20;
    final spreadDeg = actions.length <= 4 ? 48.0 : 56.0;
    final spread = spreadDeg * math.pi / 180;
    final half = tapSize / 2;
    final cy = height / 2;

    final children = <Widget>[];
    for (var i = 0; i < actions.length; i++) {
      final n = actions.length;
      // -1 .. 1（单个动作时居中）
      final t = n == 1 ? 0.0 : (i / (n - 1)) * 2 - 1;
      final angle = t * spread;

      // 弧心在容器右侧外面：**凹面朝向角色** ——
      // 中间最靠左（离角色最远）、两端靠右（迎向角色轮廓），
      // 整体像一弯「包住」角色的月牙。
      final xCenter = half + radius * (1 - math.cos(angle));
      final yCenter = cy + radius * math.sin(angle);

      children.add(
        Positioned(
          left: (flip ? barWidth - tapSize - (xCenter - half) : xCenter - half)
              .clamp(0.0, barWidth - tapSize),
          top: (yCenter - half).clamp(0.0, math.max(0.0, height - tapSize)),
          child: _ArcButton(
            action: actions[i],
            dragging: dragging,
            onDragStart: onDragStart,
            onDragUpdate: onDragUpdate,
            onDragEnd: onDragEnd,
            onDragCancel: onDragCancel,
          ),
        ),
      );
    }

    return SizedBox(
      width: barWidth,
      height: height,
      child: Stack(children: children),
    );
  }
}

class _ArcButton extends StatelessWidget {
  const _ArcButton({
    required this.action,
    required this.dragging,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onDragCancel,
  });

  final ArcAction action;
  final bool dragging;
  final VoidCallback? onDragStart;
  final void Function(DragUpdateDetails details)? onDragUpdate;
  final VoidCallback? onDragEnd;
  final VoidCallback? onDragCancel;
  @override
  Widget build(BuildContext context) {
    final enabled = action.enabled;
    // 无背景的纯图标要在**浅色和深色**页面上都看得清：
    // 用深色图标 + 白色外发光当描边（深色背景上白晕把图标衬出来）
    final Color tint;
    if (!enabled) {
      tint = const Color(0x662B3B55);
    } else if (action.danger) {
      tint = const Color(0xFFE5484D); // 关闭：红色
    } else if (dragging && action.isDragHandle) {
      tint = const Color(0xFF2F6BFF); // 拖动中：主题蓝
    } else {
      tint = const Color(0xFF2B3B55);
    }
    final icon = Icon(
      action.icon,
      size: ArcActionBar.iconSize,
      color: tint,
      shadows: enabled
          ? const <Shadow>[
              Shadow(color: Color(0xFFFFFFFF), blurRadius: 6),
              Shadow(color: Color(0xE6FFFFFF), blurRadius: 2),
              Shadow(color: Color(0x33000000), blurRadius: 10, offset: Offset(0, 1)),
            ]
          : null,
    );

    // 大点击区：透明 40×40，视觉上只有图标
    final tap = SizedBox(
      width: ArcActionBar.tapSize,
      height: ArcActionBar.tapSize,
      child: Center(child: icon),
    );

    Widget content;
    if (action.isDragHandle) {
      content = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => onDragStart?.call(),
        onPanUpdate: onDragUpdate,
        onPanEnd: (_) => onDragEnd?.call(),
        onPanCancel: onDragCancel,
        child: tap,
      );
    } else {
      content = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? action.onTap : null,
        child: tap,
      );
    }

    final tooltip = action.tooltip;
    if (tooltip == null || tooltip.isEmpty) return content;
    return Tooltip(message: tooltip, child: content);
  }
}
