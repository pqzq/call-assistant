import 'package:flutter/material.dart';

/// 统一的确认弹窗
///
/// - 取消与确认按钮**固定在同一行**，宽度一致，视觉对称
/// - 确认按钮用实心主题色（危险操作用红色），一眼能找到
/// - 取消按钮用描边样式，不抢主操作的视觉权重
class ConfirmDialog extends StatelessWidget {
  const ConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    this.confirmText = '确定',
    this.cancelText = '取消',
    this.destructive = false,
    this.icon,
  });

  final String title;
  final String message;

  /// 确认按钮文案
  final String confirmText;

  /// 取消按钮文案
  final String cancelText;

  /// 危险操作（删除/清空）时确认按钮用红色
  final bool destructive;

  final IconData? icon;

  /// 弹一个确认框，返回 true 表示用户点了确认
  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String message,
    String confirmText = '确定',
    String cancelText = '取消',
    bool destructive = false,
    IconData? icon,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => ConfirmDialog(
        title: title,
        message: message,
        confirmText: confirmText,
        cancelText: cancelText,
        destructive: destructive,
        icon: icon,
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = destructive ? const Color(0xFFD03B3B) : theme.colorScheme.primary;
    return AlertDialog(
      title: Row(
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 20, color: accent),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      content: Text(
        message,
        style: const TextStyle(fontSize: 14, height: 1.5, color: Colors.black87),
      ),
      // 两个按钮同一行、宽度一致
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      actions: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(false),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                  foregroundColor: const Color(0xFF5B6B84),
                  side: const BorderSide(color: Color(0xFFD7DEE9)),
                ),
                child: Text(cancelText),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                  backgroundColor: accent,
                ),
                child: Text(confirmText),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
