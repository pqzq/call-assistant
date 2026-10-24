import 'package:flutter/material.dart';

import '../services/platform_bridge.dart';
import '../services/prompt_link.dart';
import '../utils/avatar_layout.dart';
import 'avatar_stage.dart';
import 'live2d_avatar.dart';

/// 全局浮动的 Live2D 数字人：
/// - 展开态：上半部分是「角色 + 右侧操作栏」，下半部分是话术框（宽度与上方对齐，可单独收起）
/// - 贴边态：像微信通话「最小化」一样缩到屏幕边缘，只留一个小挂件，点击或拖动即恢复
///
/// 说明：Live2D 用 WebView（平台视图）渲染。平台视图上已加 IgnorePointer，
/// 因此角色区域/状态/话术框的点击都会穿透到下面的页面，只有操作栏和挂件按钮可交互。
class FloatingAvatarHost extends StatefulWidget {
  const FloatingAvatarHost({super.key, required this.child});

  final Widget child;

  /// 右侧竖排操作栏宽度
  static const double barWidth = 36;

  /// 角色组（角色 + 操作栏）占屏幕宽度的比例
  static const double groupRatio = 0.8;

  /// 角色组宽度上下限
  static const double groupMinWidth = 240;
  static const double groupMaxWidth = 460;

  /// 贴边时（缩小）尺寸
  static const double dockedWidth = 116;
  static const double dockedHeight = 146;

  /// 角色盒与操作栏之间的间隔
  static const double barGap = 4;

  /// 贴边判定阈值（距屏幕边缘多少像素内触发）
  static const double dockThreshold = 36;

  /// 话术框最大高度
  static const double bubbleMaxHeight = 150;

  /// 角色组宽度：约占屏幕一半
  static double groupWidth(double screenWidth) => (screenWidth * groupRatio)
      .clamp(groupMinWidth, groupMaxWidth)
      .toDouble();

  /// 角色盒宽度（角色组减去操作栏）
  static double avatarBoxWidth(double screenWidth) =>
      groupWidth(screenWidth) - barWidth - barGap;

  /// 角色盒高度：与宽度成比例，看起来比之前更大
  static double avatarHeight(double screenWidth) =>
      (avatarBoxWidth(screenWidth) * 1.42).clamp(220.0, 330.0).toDouble();

  @override
  State<FloatingAvatarHost> createState() => _FloatingAvatarHostState();
}

class _FloatingAvatarHostState extends State<FloatingAvatarHost> {
  /// 拖动中的像素坐标（左上角）
  Offset? _dragPos;
  bool _dragging = false;

  /// 是否处于贴边（最小化）状态
  bool _docked = false;

  /// 贴在哪一侧
  bool _dockRight = true;

  /// 贴边时拖动前的锚点
  Offset _dockAnchor = Offset.zero;

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
        return LayoutBuilder(
          builder: (context, constraints) {
            final screen = Size(constraints.maxWidth, constraints.maxHeight);
            final groupWidth = FloatingAvatarHost.groupWidth(screen.width);
            final avatarHeight = FloatingAvatarHost.avatarHeight(screen.width);
            final bubbleHeight = link.bubbleCollapsed ? 0.0 : FloatingAvatarHost.bubbleMaxHeight;
            final expandedWidth = groupWidth;
            final expandedHeight = avatarHeight + (bubbleHeight > 0 ? bubbleHeight + 8 : 0);
            return Stack(
              children: <Widget>[
                widget.child,
                // 展开/贴边之间用尺寸插值做过渡
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(end: _docked ? 1 : 0),
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, _) {
                    final unitWidth = _lerp(expandedWidth, FloatingAvatarHost.dockedWidth, t);
                    final boxHeight = _lerp(avatarHeight, FloatingAvatarHost.dockedHeight, t);
                    final unitHeight = _lerp(expandedHeight, FloatingAvatarHost.dockedHeight, t);
                    final free = Size(
                      (screen.width - unitWidth).clamp(0.0, double.infinity).toDouble(),
                      (screen.height - unitHeight).clamp(0.0, double.infinity).toDouble(),
                    );
                    final pos = _resolvePosition(link, free, screen);
                    return AnimatedPositioned(
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.easeOutCubic,
                      left: pos.dx,
                      top: pos.dy,
                      child: _buildUnit(
                        link,
                        free,
                        t,
                        boxHeight,
                        unitWidth,
                        groupWidth,
                      ),
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  /// 计算当前左上角位置
  Offset _resolvePosition(PromptLink link, Size free, Size screen) {
    if (_docked) {
      final left = _dockRight ? screen.width - FloatingAvatarHost.dockedWidth : 0.0;
      final top = (_dragPos?.dy ?? link.avatarPosY * free.height)
          .clamp(0.0, free.height)
          .toDouble();
      return Offset(left, top);
    }
    final stored = _dragPos ?? AvatarLayout.resolve(link.avatarPosX, link.avatarPosY, free);
    final clamped = AvatarLayout.clampPixel(stored, free);
    return Offset(clamped.dx, clamped.dy);
  }

  Widget _buildUnit(
    PromptLink link,
    Size free,
    double t,
    double avatarHeight,
    double unitWidth,
    double groupWidth,
  ) {
    final docked = t > 0.5;
    // 浮层没有 Material 祖先，必须给 DefaultTextStyle，
    // 否则文字会落到 Flutter 的 fallback 样式（红字 + 黄色双下划线）
    final textStyle = Theme.of(context).textTheme.bodyMedium ??
        const TextStyle(fontSize: 14, color: Colors.black87, height: 1.4);
    return DefaultTextStyle(
      style: textStyle,
      child: SizedBox(
        width: unitWidth,
        child: docked
            ? _buildDockedChip(link, avatarHeight)
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    // 操作栏高度自适应，靠 crossAxisAlignment 垂直居中于角色
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      // 必须给固定宽度：放进 Row 后 Column 拿到的是无界宽度，
                      // Live2dAvatar 内部的 width: double.infinity 会变成无限宽导致渲染失败
                      SizedBox(
                        width: groupWidth - FloatingAvatarHost.barWidth - FloatingAvatarHost.barGap,
                        height: avatarHeight,
                        child: Live2dAvatar(
                          modelPath: link.avatarModel,
                          mouth: link.mouth,
                          height: avatarHeight,
                        ),
                      ),
                      _buildSideBar(link, free),
                    ],
                  ),
                  if (!link.bubbleCollapsed) ...<Widget>[
                    const SizedBox(height: 8),
                    // 话术框与上方「角色 + 操作栏」整体左对齐、宽度一致
                    // （宽度用 double.infinity 继承容器宽度，避免出现偏差）
                    AvatarBubble(
                      link: link,
                      maxHeight: FloatingAvatarHost.bubbleMaxHeight,
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  // ---------------- 贴边小挂件 ----------------

  Widget _buildDockedChip(PromptLink link, double avatarHeight) {
    final status = link.avatarStatus;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _restoreFromDock,
      onPanStart: (_) => setState(() => _dragging = true),
      onPanUpdate: (details) {
        // 从贴边状态拖动 -> 立即恢复展开并继续跟随
        setState(() {
          if (_docked) {
            _docked = false;
            _dragPos = _dockAnchor;
          }
          _dragPos = (_dragPos ?? Offset.zero) + details.delta;
        });
      },
      onPanEnd: (_) async {
        setState(() => _dragging = false);
        await _persistPosition(free: _freeSizeForExpanded());
      },
      child: SizedBox(
        width: FloatingAvatarHost.dockedWidth,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            // 贴边时也显示模型（小挂件），点一下展开
            Live2dAvatar(
              modelPath: link.avatarModel,
              mouth: link.mouth,
              height: avatarHeight,
            ),
            // 恢复按钮（画在 WebView 之上，命中测试优先）
            // 贴右边时按钮放左下角，避免被屏幕边缘切掉
            Positioned(
              right: _dockRight ? null : -2,
              left: _dockRight ? -2 : null,
              bottom: -2,
              child: _RoundButton(
                icon: Icons.open_in_full_rounded,
                tooltip: '展开数字人',
                onTap: _restoreFromDock,
              ),
            ),
            // 状态小圆点
            Positioned(
              left: 2,
              top: 2,
              child: IgnorePointer(
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: _statusColor(status),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _restoreFromDock() {
    final link = PromptLink.instance;
    final free = _freeSizeForExpanded();
    // 没拖动过时 _dragPos 为空，要用已保存的位置，否则会跳到左上角
    final current = _dragPos ?? AvatarLayout.resolve(link.avatarPosX, link.avatarPosY, free);
    setState(() {
      _docked = false;
      _dragPos = AvatarLayout.clampPixel(current, free);
    });
  }

  // ---------------- 右侧操作栏 ----------------

  Widget _buildSideBar(PromptLink link, Size free) {
    // 桌面端用深色玻璃：浅灰背景上不会糊成一条「灰条」，
    // 深色背景上也能保持清晰
    final dark = PlatformBridge.isDesktop;
    final barColor = dark
        ? const Color(0xFF2A3242).withValues(alpha: _dragging ? 0.95 : 0.82)
        : Colors.white.withValues(alpha: _dragging ? 0.95 : 0.85);
    final iconColor = dark ? Colors.white : const Color(0xFF6B7A99);
    final iconColorOff = dark ? Colors.white38 : Colors.black26;
    return Container(
      width: FloatingAvatarHost.barWidth,
      margin: const EdgeInsets.only(left: FloatingAvatarHost.barGap),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: barColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: dark ? Colors.white.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.06),
        ),
        boxShadow: dark
            ? <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 拖动
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => setState(() => _dragging = true),
            onPanUpdate: (details) => _onDragUpdate(link, free, details.delta),
            onPanEnd: (_) => _onDragEnd(link, free),
            onPanCancel: () => setState(() => _dragging = false),
            child: SizedBox(
              width: FloatingAvatarHost.barWidth,
              height: 36,
              child: Icon(Icons.drag_indicator, size: 18, color: iconColor),
            ),
          ),
          _sideButton(
            iconColor: iconColor,
            iconColorOff: iconColorOff,
            icon: Icons.chevron_left,
            tooltip: '上一步',
            enabled: link.stepIndex > 0,
            onTap: link.previousStep,
          ),
          _sideButton(
            iconColor: iconColor,
            iconColorOff: iconColorOff,
            icon: Icons.chevron_right,
            tooltip: '下一步',
            enabled: link.stepIndex < link.scriptSteps.length - 1,
            onTap: link.nextStep,
          ),
          // 话术框收起/展开
          _sideButton(
            iconColor: iconColor,
            iconColorOff: iconColorOff,
            icon: link.bubbleCollapsed ? Icons.chat_bubble_outline : Icons.chat_bubble,
            tooltip: link.bubbleCollapsed ? '展开话术框' : '收起话术框',
            onTap: () => link.setBubbleCollapsed(!link.bubbleCollapsed),
          ),
          _sideButton(
            iconColor: iconColor,
            iconColorOff: iconColorOff,
            icon: Icons.compress_rounded,
            tooltip: '贴边收起',
            onTap: _dockToEdge,
          ),
          _sideButton(
            iconColor: iconColor,
            iconColorOff: iconColorOff,
            icon: Icons.close,
            tooltip: '关闭数字人',
            onTap: () => link.setAvatarEnabled(false),
          ),
        ],
      ),
    );
  }

  Widget _sideButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    required Color iconColor,
    required Color iconColorOff,
    bool enabled = true,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: FloatingAvatarHost.barWidth,
          height: 36,
          child: Icon(
            icon,
            size: 17,
            color: enabled ? iconColor : iconColorOff,
          ),
        ),
      ),
    );
  }

  // ---------------- 话术框（含状态信息） ----------------

  // ---------------- 拖动 / 贴边 ----------------

  Size _freeSizeForExpanded() {
    final media = MediaQuery.of(context);
    final groupWidth = FloatingAvatarHost.groupWidth(media.size.width);
    final bubbleHeight =
        PromptLink.instance.bubbleCollapsed ? 0.0 : FloatingAvatarHost.bubbleMaxHeight;
    return Size(
      (media.size.width - groupWidth).clamp(0.0, double.infinity).toDouble(),
      (media.size.height -
              FloatingAvatarHost.avatarHeight(media.size.width) -
              bubbleHeight -
              8)
          .clamp(0.0, double.infinity)
          .toDouble(),
    );
  }

  void _onDragUpdate(PromptLink link, Size free, Offset delta) {
    setState(() {
      final current = _dragPos ?? AvatarLayout.resolve(link.avatarPosX, link.avatarPosY, free);
      _dragPos = AvatarLayout.clampPixel(current + delta, free);
    });
  }

  Future<void> _onDragEnd(PromptLink link, Size free) async {
    setState(() => _dragging = false);
    final pos = _dragPos;
    if (pos == null) return;

    final media = MediaQuery.of(context);
    final unitWidth = FloatingAvatarHost.groupWidth(media.size.width);
    // 靠近左右边缘 -> 自动贴边收起
    final nearLeft = pos.dx <= FloatingAvatarHost.dockThreshold;
    final nearRight = (media.size.width - (pos.dx + unitWidth)) <= FloatingAvatarHost.dockThreshold;
    if (nearLeft || nearRight) {
      setState(() {
        _docked = true;
        _dockRight = nearRight && !nearLeft;
        _dockAnchor = pos;
      });
      return;
    }
    await _persistPosition(free: free);
  }

  void _dockToEdge() {
    final media = MediaQuery.of(context);
    final free = _freeSizeForExpanded();
    final link = PromptLink.instance;
    // 用实际位置判断贴哪一侧（_dragPos 为空时取已保存的位置）
    final currentLeft = _dragPos?.dx ??
        AvatarLayout.resolve(link.avatarPosX, link.avatarPosY, free).dx;
    final center = currentLeft + FloatingAvatarHost.groupWidth(media.size.width) / 2;
    setState(() {
      _dockRight = center > media.size.width / 2;
      _dockAnchor = _dragPos ?? Offset.zero;
      _docked = true;
    });
  }

  Future<void> _persistPosition({required Size free}) async {
    final pos = _dragPos;
    if (pos == null) return;
    final normalized = AvatarLayout.normalize(pos, free);
    await PromptLink.instance.setAvatarPosition(normalized.dx, normalized.dy);
  }

  static Color _statusColor(AvatarStatus status) {
    switch (status) {
      case AvatarStatus.disabled:
        return const Color(0xFF9AA4B2);
      case AvatarStatus.ready:
        return const Color(0xFF17A05A);
      case AvatarStatus.armed:
        return const Color(0xFF2F6BFF);
      case AvatarStatus.speaking:
        return const Color(0xFFE07A00);
      case AvatarStatus.error:
        return const Color(0xFFD03B3B);
    }
  }
}

/// 圆形小按钮（贴边挂件上的恢复按钮）
class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.tooltip, this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        elevation: 3,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 28,
            height: 28,
            child: Icon(icon, size: 15, color: const Color(0xFF2F6BFF)),
          ),
        ),
      ),
    );
  }
}
