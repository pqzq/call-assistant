import 'dart:ui';

import 'package:flutter/material.dart';

/// 液态玻璃（Liquid Glass）风格容器。
///
/// 组成：
/// - 背景强模糊（BackdropFilter）
/// - 半透明白色渐变（模拟玻璃的通透感）
/// - 1px 高光描边 + 顶部更亮的镜面反射
/// - 柔和的大范围投影，让它看起来是「浮」在内容之上
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = 26,
    this.blur = 20,
    this.opacity = 0.78,
    this.padding,
    this.margin,
    this.elevated = true,
    this.tint,
  });

  final Widget child;
  final double borderRadius;

  /// 背景模糊强度
  final double blur;

  /// 玻璃底色不透明度
  final double opacity;

  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  /// 是否带悬浮投影
  final bool elevated;

  /// 可选的色调（默认冷白玻璃）
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final base = tint ?? const Color(0xFFFFFFFF);
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: elevated
            ? <BoxShadow>[
                BoxShadow(
                  color: const Color(0xFF0B1F3A).withValues(alpha: 0.16),
                  blurRadius: 26,
                  spreadRadius: -4,
                  offset: const Offset(0, 12),
                ),
                BoxShadow(
                  color: const Color(0xFF0B1F3A).withValues(alpha: 0.08),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  base.withValues(alpha: opacity),
                  base.withValues(alpha: opacity * 0.72),
                  base.withValues(alpha: opacity * 0.88),
                ],
                stops: const <double>[0, 0.55, 1],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.85),
                width: 1,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 液态玻璃导航条（悬浮在内容之上）
class GlassNavBar extends StatelessWidget {
  const GlassNavBar({super.key, required this.child, this.margin});

  final Widget child;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      margin: margin,
      borderRadius: 24,
      blur: 24,
      opacity: 0.82,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: child,
    );
  }
}

/// 液态玻璃主按钮（悬浮在页面底部）
class GlassActionButton extends StatelessWidget {
  const GlassActionButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.enabled = true,
  });

  final VoidCallback? onPressed;
  final IconData icon;
  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final active = enabled && onPressed != null;
    return GlassSurface(
      borderRadius: 30,
      blur: 22,
      opacity: active ? 0.86 : 0.6,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: active ? onPressed : null,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              icon,
              size: 20,
              color: active ? const Color(0xFF2F6BFF) : Colors.black26,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: active ? const Color(0xFF1B2A44) : Colors.black26,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 玻璃导航条里的选中项（更亮的一小块玻璃）
class GlassNavItem extends StatelessWidget {
  const GlassNavItem({
    super.key,
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? const Color(0xFF2F6BFF) : const Color(0xFF7A879B);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: selected
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[Color(0xFFFFFFFF), Color(0xFFE6EEFF)],
                )
              : null,
          boxShadow: selected
              ? <BoxShadow>[
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.9),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                  BoxShadow(
                    color: const Color(0xFF2F6BFF).withValues(alpha: 0.18),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 19, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
