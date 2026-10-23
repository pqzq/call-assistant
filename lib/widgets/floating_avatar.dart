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

  /// 数字人可视区域尺寸（150×190 的两倍，方便看清模型细节）
  static const double avatarWidth = 300;
  static const double avatarHeight = 380;

  /// 底部控制条高度（拖动 / 关闭）
  static const double barHeight = 40;

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
    // 整体透明：只有角色本身和底部控制条，不做底板/阴影，避免遮挡页面文字
    return Material(
      color: Colors.transparent,
      child: SizedBox(
        width: FloatingAvatarHost.avatarWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 注意：不要给平台视图套 IgnorePointer —— 放弃 Flutter 命中测试后，
            // Android 层会把这一带触摸直接派发给 WebView，连下方控制条都点不动。
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
    // 半透明小胶囊：整块背景透明后，手柄仍要看得见、抓得住
    return SizedBox(
      height: FloatingAvatarHost.barHeight,
      child: Center(
        child: Container(
          height: 26,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: _dragging ? 0.92 : 0.55),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 拖动区域
              GestureDetector(
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
                child: const SizedBox(
                  width: 62,
                  height: 26,
                  child: Icon(Icons.drag_indicator, size: 18, color: Color(0xFF6B7A99)),
                ),
              ),
              Container(width: 1, height: 14, color: const Color(0xFFD6DEEE)),
              InkWell(
                onTap: () => link.setAvatarEnabled(false),
                borderRadius: BorderRadius.circular(13),
                child: const SizedBox(
                  width: 32,
                  height: 26,
                  child: Icon(Icons.close, size: 15, color: Color(0xFF6B7A99)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
