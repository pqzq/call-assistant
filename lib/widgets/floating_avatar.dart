import 'package:flutter/material.dart';

import '../services/prompt_link.dart';
import '../utils/avatar_layout.dart';
import 'live2d_avatar.dart';

/// 全局浮动的 Live2D 数字人：
/// - 展开态：角色 + 右侧竖排操作栏 + 话术框（状态信息并入话术框顶部）
/// - 贴边态：像微信通话「最小化」一样缩到屏幕边缘，只留一个小挂件，点击或拖动即恢复
///
/// 说明：Live2D 用 WebView（平台视图）渲染。平台视图上已加 IgnorePointer，
/// 因此角色区域/状态/话术框的点击都会穿透到下面的页面，只有操作栏和挂件按钮可交互。
class FloatingAvatarHost extends StatefulWidget {
  const FloatingAvatarHost({super.key, required this.child});

  final Widget child;

  /// 展开时角色区尺寸（Live2D 角色在盒子里居中，盒子可以比角色窄一些）
  static const double avatarWidth = 176;
  static const double avatarHeight = 264;

  /// 贴边时（缩小）尺寸
  static const double dockedWidth = 116;
  static const double dockedHeight = 146;

  /// 右侧竖排操作栏宽度
  static const double barWidth = 36;

  /// 展开态整体宽度（气泡 + 角色 + 操作栏），按屏幕宽度动态计算
  static const double expandedWidth = avatarWidth + 6 + barWidth;

  /// 话术框宽度上限
  static const double bubbleMaxWidth = 220;

  /// 话术框宽度下限
  static const double bubbleMinWidth = 120;

  /// 话术框最大高度
  static const double bubbleMaxHeight = 178;

  /// 贴边判定阈值（距屏幕边缘多少像素内触发）
  static const double dockThreshold = 36;

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
            return Stack(
              children: <Widget>[
                widget.child,
                // 展开/贴边之间用尺寸插值做过渡
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(end: _docked ? 1 : 0),
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, _) {
                    // 气泡在角色左侧，三栏并排：整体高度 = 角色高度，不浪费竖向空间
                    final bubbleWidth = _bubbleWidthFor(screen.width);
                    final expandedWidth = bubbleWidth +
                        6 +
                        FloatingAvatarHost.avatarWidth +
                        FloatingAvatarHost.barWidth;
                    final unitWidth = _lerp(expandedWidth, FloatingAvatarHost.dockedWidth, t);
                    final avatarHeight =
                        _lerp(FloatingAvatarHost.avatarHeight, FloatingAvatarHost.dockedHeight, t);
                    final unitHeight = avatarHeight;
                    final free = Size(
                      (screen.width - unitWidth).clamp(0.0, double.infinity).toDouble(),
                      (screen.height - unitHeight).clamp(0.0, double.infinity).toDouble(),
                    );
                    final pos = _resolvePosition(link, free, screen, t);
                    return AnimatedPositioned(
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.easeOutCubic,
                      left: pos.dx,
                      top: pos.dy,
                      child: _buildUnit(
                        link,
                        free,
                        t,
                        avatarHeight,
                        unitWidth,
                        bubbleWidth,
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
  Offset _resolvePosition(PromptLink link, Size free, Size screen, double t) {
    if (_docked) {
      final left = _dockRight ? screen.width - FloatingAvatarHost.dockedWidth : 0.0;
      final top = (_dragPos?.dy ?? link.avatarPosY * free.height).clamp(0.0, free.height).toDouble();
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
    double bubbleWidth,
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
            : Row(
                // 话术框 / 角色 / 操作栏 三栏并排、顶部对齐
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _buildBubble(link, bubbleWidth, avatarHeight),
                  const SizedBox(width: 6),
                  // 必须给固定宽度：放进 Row 后 Column 拿到的是无界宽度，
                  // Live2dAvatar 内部的 width: double.infinity 会变成无限宽导致渲染失败
                  SizedBox(
                    width: FloatingAvatarHost.avatarWidth,
                    height: avatarHeight,
                    child: Live2dAvatar(
                      modelPath: link.avatarModel,
                      mouth: link.mouth,
                      height: avatarHeight,
                    ),
                  ),
                  _buildSideBar(link, free, avatarHeight),
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

  Widget _buildSideBar(PromptLink link, Size free, double avatarHeight) {
    return SizedBox(
      // 与角色等高，顶部对齐
      height: avatarHeight,
      width: FloatingAvatarHost.barWidth,
      child: Container(
        margin: const EdgeInsets.only(left: 4),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: _dragging ? 0.95 : 0.82),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
        ),
        child: Column(
          // 图标沿高度均匀分布，点击区域更大
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: <Widget>[
            // 拖动
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => setState(() => _dragging = true),
              onPanUpdate: (details) => _onDragUpdate(link, free, details.delta),
              onPanEnd: (_) => _onDragEnd(link, free),
              onPanCancel: () => setState(() => _dragging = false),
              child: const SizedBox(
                width: FloatingAvatarHost.barWidth,
                height: 40,
                child: Icon(Icons.drag_indicator, size: 19, color: Color(0xFF6B7A99)),
              ),
            ),
            _sideButton(
              icon: Icons.chevron_left,
              tooltip: '上一步',
              enabled: link.stepIndex > 0,
              onTap: link.previousStep,
            ),
            _sideButton(
              icon: Icons.chevron_right,
              tooltip: '下一步',
              enabled: link.stepIndex < link.scriptSteps.length - 1,
              onTap: link.nextStep,
            ),
            _sideButton(
              icon: Icons.compress_rounded,
              tooltip: '贴边收起',
              onTap: _dockToEdge,
            ),
            _sideButton(
              icon: Icons.close,
              tooltip: '关闭数字人',
              onTap: () => link.setAvatarEnabled(false),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sideButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    bool enabled = true,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: FloatingAvatarHost.barWidth,
          height: 40,
          child: Icon(
            icon,
            size: 18,
            color: enabled ? const Color(0xFF6B7A99) : Colors.black26,
          ),
        ),
      ),
    );
  }

  // ---------------- 话术框（含状态信息） ----------------

  Widget _buildBubble(PromptLink link, double bubbleWidth, double bubbleHeight) {
    final lead = link.activeLead;
    final steps = link.scriptSteps;
    final step = link.currentStep;
    final status = link.avatarStatus;
    // 纯展示：整体不可命中，避免挡住下面的内容
    return IgnorePointer(
      child: Container(
        width: bubbleWidth,
        height: bubbleHeight,
        padding: const EdgeInsets.fromLTRB(11, 8, 11, 8),
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
              // 状态行（整合到话术框顶部）
              Row(
                children: <Widget>[
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _statusColor(status),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    status.label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _statusColor(status),
                    ),
                  ),
                  if (lead != null) ...<Widget>[
                    const SizedBox(width: 6),
                    const Text('·', style: TextStyle(fontSize: 12, color: Colors.black26)),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 150),
                      child: Text(
                        lead.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                    ),
                  ],
                ],
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 7),
                child: Divider(height: 1, color: Color(0xFFEEF1F7)),
              ),
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
                const SizedBox(height: 6),
                Text(
                  '话术 ${link.stepIndex + 1}/${steps.length}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2F6BFF),
                  ),
                ),
                const SizedBox(height: 3),
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

  // ---------------- 拖动 / 贴边 ----------------

  /// 展开态的可用区域（话术框 + 角色 + 操作栏 并排，高度=角色高）
  Size _freeSizeForExpanded() {
    final media = MediaQuery.of(context);
    final bubbleWidth = _bubbleWidthFor(media.size.width);
    final width = bubbleWidth + 6 + FloatingAvatarHost.avatarWidth + FloatingAvatarHost.barWidth;
    return Size(
      (media.size.width - width).clamp(0.0, double.infinity).toDouble(),
      (media.size.height - FloatingAvatarHost.avatarHeight).clamp(0.0, double.infinity).toDouble(),
    );
  }

  double _bubbleWidthFor(double screenWidth) =>
      (screenWidth - FloatingAvatarHost.avatarWidth - FloatingAvatarHost.barWidth - 12)
          .clamp(
            FloatingAvatarHost.bubbleMinWidth,
            FloatingAvatarHost.bubbleMaxWidth,
          )
          .toDouble();

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
    final unitWidth = _bubbleWidthFor(media.size.width) +
        6 +
        FloatingAvatarHost.avatarWidth +
        FloatingAvatarHost.barWidth;
    // 靠近左右边缘 -> 自动贴边收起
    final nearLeft = pos.dx <= FloatingAvatarHost.dockThreshold;
    final nearRight = (media.size.width - (pos.dx + unitWidth)) <= FloatingAvatarHost.dockThreshold;
    if (nearLeft || nearRight) {
      setState(() {
        _docked = true;
        _dockRight = nearRight && !nearLeft;
        _dockAnchor = pos;
        _dragPos = Offset(pos.dx, pos.dy);
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
    final center = currentLeft + FloatingAvatarHost.expandedWidth / 2;
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
