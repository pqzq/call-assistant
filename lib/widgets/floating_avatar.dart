import 'package:flutter/material.dart';

import '../services/prompt_link.dart';
import '../utils/avatar_layout.dart';
import 'live2d_avatar.dart';

/// 全局浮动的 Live2D 数字人（状态条 + 提词气泡），浮在所有页面之上，可拖动。
///
/// 说明：Live2D 用 WebView（平台视图）渲染，平台视图会吃掉其范围内的触摸，
/// 所以所有可点元素（拖动、折叠、关闭、下一步）都放在视图外的区域。
class FloatingAvatarHost extends StatefulWidget {
  const FloatingAvatarHost({super.key, required this.child});

  final Widget child;

  /// 展开时的数字人尺寸
  static const double avatarWidth = 300;
  static const double avatarHeight = 380;

  /// 折叠后的小头像尺寸
  static const double miniWidth = 104;
  static const double miniHeight = 132;

  /// 顶部状态条
  static const double stripHeight = 30;

  /// 底部控制条（拖动 / 折叠 / 关闭）
  static const double barHeight = 44;

  /// 提词气泡最大高度
  static const double bubbleMaxHeight = 178;

  @override
  State<FloatingAvatarHost> createState() => _FloatingAvatarHostState();
}

class _FloatingAvatarHostState extends State<FloatingAvatarHost> {
  Offset? _dragPos;
  bool _dragging = false;

  double get _unitWidth =>
      PromptLink.instance.collapsed ? FloatingAvatarHost.miniWidth : FloatingAvatarHost.avatarWidth;

  Size _freeSize(BoxConstraints constraints) {
    final collapsed = PromptLink.instance.collapsed;
    final width = collapsed ? FloatingAvatarHost.miniWidth : FloatingAvatarHost.avatarWidth;
    final height = collapsed
        ? FloatingAvatarHost.miniHeight + FloatingAvatarHost.barHeight
        : FloatingAvatarHost.stripHeight +
            FloatingAvatarHost.avatarHeight +
            FloatingAvatarHost.bubbleMaxHeight +
            FloatingAvatarHost.barHeight;
    return Size(
      (constraints.maxWidth - width).clamp(0.0, double.infinity),
      (constraints.maxHeight - height).clamp(0.0, double.infinity),
    );
  }

  @override
  Widget build(BuildContext context) {
    final link = PromptLink.instance;
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) {
        if (!link.avatarEnabled || link.suppressAvatar) {
          _dragPos = null;
          return widget.child;
        }
        // LayoutBuilder 必须在 Stack 外层：Positioned 只有当 Stack 的直接子节点才生效
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
                  child: _buildUnit(link, free),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildUnit(PromptLink link, Size free) {
    final collapsed = link.collapsed;
    // 注意：这里不能用 Material/Container 之类的装饰性容器包住整体，
    // 它们会吃掉整块区域的点击，导致浮窗下方的号码/按钮点不动。
    // 纯展示部分统一用 IgnorePointer，只有底部控制条保持可交互。
    //
    // 另外浮层挂在 MaterialApp.builder 上、没有 Material 祖先，
    // 不给 DefaultTextStyle 的话会落到 Flutter 的 fallback 样式（红字+黄色下划线）
    final textStyle = Theme.of(context).textTheme.bodyMedium ??
        const TextStyle(fontSize: 14, color: Colors.black87, height: 1.4);
    return DefaultTextStyle(
      style: textStyle,
      child: SizedBox(
        width: _unitWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (!collapsed) ...<Widget>[
              _buildStatusStrip(link),
              const SizedBox(height: 4),
            ],
            Live2dAvatar(
              modelPath: link.avatarModel,
              mouth: link.mouth,
              height: collapsed ? FloatingAvatarHost.miniHeight : FloatingAvatarHost.avatarHeight,
            ),
            if (!collapsed) ...<Widget>[
              const SizedBox(height: 6),
              _buildBubble(link),
            ],
            _buildBar(link, free),
          ],
        ),
      ),
    );
  }

  // ---------------- 状态条 ----------------

  Widget _buildStatusStrip(PromptLink link) {
    final status = link.avatarStatus;
    final (color, label) = switch (status) {
      AvatarStatus.disabled => (const Color(0xFF9AA4B2), '未启用'),
      AvatarStatus.ready => (const Color(0xFF17A05A), '待拨号'),
      AvatarStatus.armed => (const Color(0xFF2F6BFF), '等待接通'),
      AvatarStatus.speaking => (const Color(0xFFE07A00), '播报中'),
      AvatarStatus.error => (const Color(0xFFD03B3B), '异常'),
    };
    // 纯展示：整体不可命中，避免挡住下面的内容
    return IgnorePointer(
      child: SizedBox(
        height: FloatingAvatarHost.stripHeight,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            height: 26,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
                ),
                if (link.activeLead != null && status == AvatarStatus.armed) ...<Widget>[
                  const SizedBox(width: 6),
                  const Text('·', style: TextStyle(fontSize: 12, color: Colors.black26)),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 92),
                    child: Text(
                      link.activeLead!.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------- 提词气泡 ----------------

  Widget _buildBubble(PromptLink link) {
    final lead = link.activeLead;
    final steps = link.scriptSteps;
    final step = link.currentStep;
    // 气泡只是信息展示，整体不可命中（翻页按钮在底部控制条上）
    return IgnorePointer(
      child: Container(
        width: FloatingAvatarHost.avatarWidth,
        constraints: const BoxConstraints(maxHeight: FloatingAvatarHost.bubbleMaxHeight),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE1E7F2)),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (lead == null)
                const Text(
                  '拨号后这里会显示客户信息与话术提词',
                  style: TextStyle(fontSize: 12, color: Colors.black45, height: 1.5),
                )
              else ...<Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        lead.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      lead.lastCalledLabel,
                      style: TextStyle(
                        fontSize: 11,
                        color: lead.lastCalled == null ? const Color(0xFF17A05A) : Colors.black38,
                      ),
                    ),
                  ],
                ),
                if (lead.subtitle.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    lead.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ],
              if (step != null) ...<Widget>[
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Divider(height: 1, color: Color(0xFFEEF1F7)),
                ),
                Text(
                  '话术 ${link.stepIndex + 1}/${steps.length}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2F6BFF),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  step,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, height: 1.45, color: Colors.black87),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- 底部控制条 ----------------

  Widget _buildBar(PromptLink link, Size free) {
    final compact = link.collapsed;
    final steps = link.scriptSteps;
    return Container(
      height: FloatingAvatarHost.barHeight,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: _dragging ? 0.95 : 0.85),
        borderRadius: BorderRadius.circular(FloatingAvatarHost.barHeight / 2),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: <Widget>[
          // 整宽拖动区：面积大，好抓
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
                child: Icon(Icons.drag_indicator, size: 20, color: Color(0xFF6B7A99)),
              ),
            ),
          ),
          if (!compact) ...<Widget>[
            _barButton(
              icon: Icons.chevron_left,
              tooltip: '上一步',
              onTap: link.stepIndex > 0 ? link.previousStep : null,
            ),
            _barButton(
              icon: Icons.chevron_right,
              tooltip: '下一步',
              onTap: link.stepIndex < steps.length - 1 ? link.nextStep : null,
            ),
          ],
          _barButton(
            icon: compact ? Icons.unfold_more : Icons.unfold_less,
            tooltip: compact ? '展开' : '折叠成小头像',
            onTap: () => link.setCollapsed(!link.collapsed),
          ),
          _barButton(
            icon: Icons.close,
            tooltip: '关闭数字人',
            onTap: () => link.setAvatarEnabled(false),
          ),
        ],
      ),
    );
  }

  /// 控制条上的小按钮
  Widget _barButton({required IconData icon, required String tooltip, VoidCallback? onTap}) {
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 42,
          height: FloatingAvatarHost.barHeight,
          child: Icon(
            icon,
            size: 18,
            color: enabled ? const Color(0xFF6B7A99) : Colors.black26,
          ),
        ),
      ),
    );
  }
}
