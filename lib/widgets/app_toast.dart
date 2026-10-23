import 'package:flutter/material.dart';

/// 全局主题色（与 App 主色一致）
const Color kAppThemeColor = Color(0xFF2F6BFF);

/// 居中浮层提示（替代底部 SnackBar）
///
/// - 居中显示，不遮挡底部操作区
/// - 主题色渐变，带图标
/// - 自动淡入淡出，不打断操作
class AppToast {
  const AppToast._();

  /// 普通提示（主题色）
  static void show(
    BuildContext context,
    String message, {
    IconData icon = Icons.check_circle_outline,
    bool isError = false,
    Duration duration = const Duration(milliseconds: 2200),
  }) {
    _show(
      context,
      message,
      icon: icon,
      isError: isError,
      duration: duration,
    );
  }

  /// 错误提示（红色 + 警告图标）
  static void error(
    BuildContext context,
    String message, {
    Duration duration = const Duration(milliseconds: 2600),
  }) {
    _show(
      context,
      message,
      icon: Icons.error_outline,
      isError: true,
      duration: duration,
    );
  }

  static void _show(
    BuildContext context,
    String message, {
    required IconData icon,
    required bool isError,
    required Duration duration,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _ToastLayer(
        message: message,
        icon: icon,
        isError: isError,
        duration: duration,
        onFinished: () {
          if (entry.mounted) entry.remove();
        },
      ),
    );
    overlay.insert(entry);
  }
}

class _ToastLayer extends StatefulWidget {
  const _ToastLayer({
    required this.message,
    required this.icon,
    required this.isError,
    required this.duration,
    required this.onFinished,
  });

  final String message;
  final IconData icon;
  final bool isError;
  final Duration duration;
  final VoidCallback onFinished;

  @override
  State<_ToastLayer> createState() => _ToastLayerState();
}

class _ToastLayerState extends State<_ToastLayer> with SingleTickerProviderStateMixin {
  /// 一个动画走完「入场 → 停留 → 退场」全流程，
  /// 不使用 Timer/Future.delayed（否则 widget 测试的 pumpAndSettle 会一直等下去）
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onFinished();
    });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 0 ~ 0.09 入场，0.09 ~ 0.91 停留，0.91 ~ 1 退场
    final enter = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0, 0.09, curve: Curves.easeOutBack),
    );
    final exit = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.91, 1, curve: Curves.easeIn),
    );
    return Positioned.fill(
      child: IgnorePointer(
        child: SafeArea(
          child: Center(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final opacity = enter.value * (1 - exit.value);
                final scale = (0.88 + 0.12 * enter.value) * (1 - 0.08 * exit.value);
                return Opacity(
                  opacity: opacity.clamp(0.0, 1.0),
                  child: Transform.scale(
                    scale: scale,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 300),
                      margin: const EdgeInsets.symmetric(horizontal: 28),
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: widget.isError
                              ? const <Color>[Color(0xFFE8564B), Color(0xFFC63A31)]
                              : const <Color>[Color(0xFF4A82FF), Color(0xFF2F6BFF)],
                        ),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: (widget.isError ? const Color(0xFFC63A31) : kAppThemeColor)
                                .withValues(alpha: 0.34),
                            blurRadius: 24,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(widget.icon, size: 20, color: Colors.white),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              widget.message,
                              style: const TextStyle(
                                fontSize: 14,
                                height: 1.4,
                                color: Colors.white,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
