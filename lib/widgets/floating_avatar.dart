import 'package:flutter/material.dart';

import '../services/prompt_link.dart';
import 'arc_action_bar.dart';
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

  /// 弧形操作栏宽度（月亮型，图标 40 点击区 + 弧线外扩空间）
  static const double barWidth = ArcActionBar.barWidth;

  /// 贴边时（缩小）尺寸
  static const double dockedWidth = 112;
  static const double dockedHeight = 152;

  /// 角色盒与操作栏之间的间隔
  static const double barGap = 8;

  /// 贴边判定阈值（距屏幕边缘多少像素内触发）
  static const double dockThreshold = 36;

  /// 话术框最大高度
  static const double bubbleMaxHeight = 150;

  /// 角色盒的长宽比（宽 / 高）
  ///
  /// Live2D 人物模型本身是**竖长**的（约 0.6~0.75），
  /// 之前把角色盒做成横向（420×330）时，模型按高度适配后
  /// 宽度只用到一半，两侧全是空白 —— 看起来「数字人比框小很多」。
  /// 这里改成竖比例，模型能填满 90% 以上宽度。
  static const double avatarAspect = 0.72;

  /// 角色盒高度：按屏幕宽度推导（竖屏下约 58%），限制在 260~420
  static double avatarHeight(double screenWidth) =>
      (screenWidth * 0.58).clamp(260.0, 420.0).toDouble();

  /// 角色盒宽度：由高度 × 长宽比得出（不再反过来定）
  static double avatarBoxWidth(double screenWidth) =>
      avatarHeight(screenWidth) * avatarAspect;

  /// 角色组宽度 = 角色盒 + 操作栏 + 间隔
  static double groupWidth(double screenWidth) =>
      avatarBoxWidth(screenWidth) + barWidth + barGap;

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
        // 注意：这里**不能**用 Transform/AnimatedScale 做拖动反馈 ——
        // Android 的平台视图（WebView / TextureView）不支持任意变换，
        // 一旦被 transform 包裹就整块不渲染（表现成模型消失）。
        // 拖动反馈改在图标上体现（见 _buildArcBar 的 dragging 参数）。
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
                      // 月亮型操作栏放在**角色左侧**
                      _buildArcBar(link, free, avatarHeight),
                      // 数字人本体：可拖动（translucent 保证点击仍能穿透到下层）
                      GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onPanStart: (_) => setState(() => _dragging = true),
                        onPanUpdate: (d) => _onDragUpdate(link, free, d.delta),
                        onPanEnd: (_) => _onDragEnd(link, free),
                        onPanCancel: () => setState(() => _dragging = false),
                        child: SizedBox(
                          // 必须给固定宽度：放进 Row 后 Column 拿到的是无界宽度，
                          // Live2dAvatar 内部的 width: double.infinity 会变成无限宽导致渲染失败
                          width: groupWidth -
                              FloatingAvatarHost.barWidth -
                              FloatingAvatarHost.barGap,
                          height: avatarHeight,
                          child: Live2dAvatar(
                            modelPath: link.avatarModel,
                            mouth: link.mouth,
                            height: avatarHeight,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (!link.bubbleCollapsed) ...<Widget>[
                    const SizedBox(height: 6),
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

  /// 月亮型弧形操作栏（放在角色左侧）
  ///
  /// - 无背景，只有带投影的白色图标（浅色页面上也看得清）
  /// - 图标沿凸向角色的弧线排布，整体像一弯月牙
  /// - 话术只有一步时不显示上一步/下一步（避免无用按钮）
  Widget _buildArcBar(PromptLink link, Size free, double avatarHeight) {
    final steps = link.scriptSteps;
    final multiStep = steps.length > 1;
    final actions = <ArcAction>[
      const ArcAction(
        icon: Icons.drag_indicator,
        tooltip: '拖动',
        isDragHandle: true,
      ),
      if (multiStep) ...<ArcAction>[
        ArcAction(
          icon: Icons.chevron_left,
          tooltip: '上一步',
          enabled: link.stepIndex > 0,
          onTap: link.previousStep,
        ),
        ArcAction(
          icon: Icons.chevron_right,
          tooltip: '下一步',
          enabled: link.stepIndex < steps.length - 1,
          onTap: link.nextStep,
        ),
      ],
      ArcAction(
        icon: link.bubbleCollapsed ? Icons.chat_bubble_outline : Icons.chat_bubble,
        tooltip: link.bubbleCollapsed ? '展开话术框' : '收起话术框',
        onTap: () => link.setBubbleCollapsed(!link.bubbleCollapsed),
      ),
      ArcAction(
        icon: Icons.compress_rounded,
        tooltip: '贴边收起',
        onTap: _dockToEdge,
      ),
      ArcAction(
        icon: Icons.close,
        tooltip: '关闭数字人',
        onTap: () => link.setAvatarEnabled(false),
      ),
    ];
    return ArcActionBar(
      height: avatarHeight,
      actions: actions,
      // 拖动时把拖动柄高亮成主题色（不能用 transform 做反馈，会影响平台视图渲染）
      dragging: _dragging,
      onDragStart: () => setState(() => _dragging = true),
      onDragUpdate: (details) => _onDragUpdate(link, free, details.delta),
      onDragEnd: () => _onDragEnd(link, free),
      onDragCancel: () => setState(() => _dragging = false),
    );
  }

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
