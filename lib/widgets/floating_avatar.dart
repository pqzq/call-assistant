import 'package:flutter/material.dart';

import '../services/prompt_link.dart';
import '../utils/avatar_layout.dart';
import 'live2d_avatar.dart';

/// 全局浮动的 Live2D 数字人：挂在 MaterialApp.builder 上，
/// 因此它浮在所有页面之上，且可以拖动位置（位置持久化）。
///
/// 注意：Live2D 用 WebView（平台视图）渲染，平台视图会吃掉其范围内的触摸，
/// 所以拖动手柄和关闭按钮都放在视图外的底部条上。
class FloatingAvatarHost extends StatefulWidget {
  const FloatingAvatarHost({super.key, required this.child});

  final Widget child;

  /// 数字人可视区域尺寸
  static const double avatarWidth = 150;
  static const double avatarHeight = 190;

  /// 底部控制条高度（拖动 / 关闭）
  static const double barHeight = 34;

  @override
  State<FloatingAvatarHost> createState() => _FloatingAvatarHostState();
}

class _FloatingAvatarHostState extends State<FloatingAvatarHost> {
  /// 拖动过程中的像素坐标（松手时写回归一化值）
  Offset? _dragPos;
  bool _dragging = false;

  Size _freeSize(BoxConstraints constraints) {
    final w = (constraints.maxWidth - FloatingAvatarHost.avatarWidth).clamp(0.0, double.infinity);
    final h = (constraints.maxHeight - FloatingAvatarHost.avatarHeight - FloatingAvatarHost.barHeight)
        .clamp(0.0, double.infinity);
    return Size(w, h);
  }

  @override
  Widget build(BuildContext context) {
    final link = PromptLink.instance;
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) {
        if (!link.avatarEnabled) {
          _dragPos = null;
          return widget.child;
        }
        // LayoutBuilder 必须在 Stack 外层：Positioned 只有当 Stack 的直接子节点才生效，
        // 否则会被当作普通子节点铺满整个 Stack（表现为整屏发白的遮罩）
        return LayoutBuilder(
          builder: (context, constraints) {
            final free = _freeSize(constraints);
            final pos = _dragPos ?? AvatarLayout.resolve(link.avatarPosX, link.avatarPosY, free);
            final clamped = AvatarLayout.clampPixel(pos, free);
            return Stack(
              children: <Widget>[
                widget.child,
                Positioned(
                  left: clamped.dx,
                  top: clamped.dy,
                  child: _buildFloatingCard(link, free),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildFloatingCard(PromptLink link, Size free) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: FloatingAvatarHost.avatarWidth,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: const Color(0xFFEAF0FF),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: _dragging ? 0.22 : 0.14),
              blurRadius: _dragging ? 18 : 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Live2dAvatar(
              modelPath: link.avatarModel,
              mouth: link.mouth,
              height: FloatingAvatarHost.avatarHeight,
            ),
            _buildBar(link, free),
          ],
        ),
      ),
    );
  }

  Widget _buildBar(PromptLink link, Size free) {
    return SizedBox(
      height: FloatingAvatarHost.barHeight,
      child: Row(
        children: <Widget>[
          // 拖动区域
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => setState(() => _dragging = true),
              onPanUpdate: (details) {
                setState(() {
                  final current =
                      _dragPos ?? AvatarLayout.resolve(link.avatarPosX, link.avatarPosY, free);
                  _dragPos = AvatarLayout.clampPixel(
                    Offset(current.dx + details.delta.dx, current.dy + details.delta.dy),
                    free,
                  );
                });
              },
              onPanEnd: (_) async {
                final pos = _dragPos;
                setState(() => _dragging = false);
                if (pos == null) return;
                final normalized = AvatarLayout.normalize(pos, free);
                await link.setAvatarPosition(normalized.dx, normalized.dy);
              },
              onPanCancel: () => setState(() => _dragging = false),
              child: const Center(
                child: Icon(Icons.drag_indicator, size: 18, color: Color(0xFF6B7A99)),
              ),
            ),
          ),
          const VerticalDivider(width: 1, indent: 9, endIndent: 9, color: Color(0xFFD6DEEE)),
          InkWell(
            onTap: () => link.setAvatarEnabled(false),
            child: const SizedBox(
              width: 34,
              height: FloatingAvatarHost.barHeight,
              child: Icon(Icons.close, size: 16, color: Color(0xFF6B7A99)),
            ),
          ),
        ],
      ),
    );
  }
}
