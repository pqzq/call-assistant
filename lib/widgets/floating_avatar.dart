import 'package:flutter/material.dart';

import '../services/avatar_renderer.dart';
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
  static const double bubbleMaxHeight = 190;

  /// 模型比例未知时的兜底值（多数人物模型在 0.45~0.60）
  static const double defaultAvatarAspect = 0.58;

  /// 比例的安全范围（异常值不能把布局撑坏）
  static const double minAvatarAspect = 0.28;
  static const double maxAvatarAspect = 0.90;

  /// 角色盒的最小宽度
  ///
  /// 话术框和角色同宽，太窄的话提词会疯狂换行、被高度裁掉。
  /// 瘦高模型（如 Haru ≈0.45）按真实比例只有 180 宽，这里托底到 232，
  /// 模型在框内居中 —— 左右留白对称，不会再出现「只有一边空一大片」。
  static const double minAvatarBoxWidth = 232;

  /// 角色盒高度：按屏幕宽度推导（竖屏下约 58%），限制在 260~420
  static double avatarHeight(double screenWidth) =>
      (screenWidth * 0.58).clamp(260.0, 420.0).toDouble();

  /// 角色盒宽度 = 高度 × 模型真实宽高比
  ///
  /// [modelAspect] 由 WebView 加载后用 `model.getLocalBounds()` 量出
  /// 并缓存在 `PromptLink.avatarModelAspect`。拿不到（还没量过）时
  /// 回退到 [defaultAvatarAspect]。这样每个模型都能**贴着自身轮廓**做框，
  /// 不会出现「角色瘦、框很宽、两侧全空」的情况。
  static double avatarBoxWidth(double screenWidth, {double modelAspect = 0}) {
    final h = avatarHeight(screenWidth);
    final aspect = modelAspect > 0
        ? modelAspect.clamp(minAvatarAspect, maxAvatarAspect)
        : defaultAvatarAspect;
    final w = h * aspect;
    return w < minAvatarBoxWidth ? minAvatarBoxWidth : w;
  }

  /// 角色组宽度 = 角色盒 + 操作栏 + 间隔
  static double groupWidth(double screenWidth, {double modelAspect = 0}) =>
      avatarBoxWidth(screenWidth, modelAspect: modelAspect) + barWidth + barGap;

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
    final groupWidth = FloatingAvatarHost.groupWidth(screen.width,
        modelAspect: PromptLink.instance.avatarModelAspect);
            final avatarHeight = FloatingAvatarHost.avatarHeight(screen.width);
            final bubbleHeight = link.bubbleCollapsed ? 0.0 : FloatingAvatarHost.bubbleMaxHeight;
            final expandedWidth = groupWidth;
            final expandedHeight = avatarHeight + (bubbleHeight > 0 ? bubbleHeight + 8 : 0);
            return Stack(
              children: <Widget>[
                widget.child,
                // 贴边时在浮窗**外侧**放一个 Flutter 绘制的「展开」按钮。
                // 不能只靠点模型恢复：原生后端的 Live2DView 是平台视图，
                // 它会挡住 Flutter 的命中测试，点击传不到外层 GestureDetector
                // （WebView 侧能穿透是靠 CSS pointer-events，平台视图没有等价手段）。
                if (_docked)
                  Positioned(
                    // 放在屏幕**内侧**（贴左边时靠右、贴右边时靠左），
                    // 免得按钮被屏幕边缘切掉一半
                    left: _dockRight ? 6 : null,
                    right: _dockRight ? null : 6,
                    bottom: 6,
                    child: _ExpandChip(onTap: _restoreFromDock),
                  ),
                // 展开/贴边之间用尺寸插值做过渡
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(end: _docked ? 1 : 0),
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, _) {
                    final unitWidth = _lerp(expandedWidth, FloatingAvatarHost.dockedWidth, t);
                    // 裁剪框高度：展开时是「角色 + 话术框」的总高（否则话术框会被裁掉），
                    // 贴边时缩到窄条高度
                    final boxHeight =
                        _lerp(expandedHeight, FloatingAvatarHost.dockedHeight, t);
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
                        // 裁剪框高度（跟着动画走）
                        boxHeight,
                        unitWidth,
                        groupWidth,
                        // 角色盒高度：恒定，决定 WebView 尺寸，动画期间不变
                        avatarHeight,
                        // 内层总高度（角色 + 话术框）：恒定
                        expandedHeight,
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
    double clipHeight,
    double unitWidth,
    double groupWidth,
    // 角色盒高度（恒定，WebView 尺寸由它决定，动画期间不变）
    double avatarH,
    // 内层总高度 = 角色 + 话术框（恒定，避免动画期间 resize 平台视图）
    double contentH,
  ) {
    // 贴边进度：过一半后进入「紧凑模式」——
    // 模型在**渲染视图内部**缩小（WebView 侧 setCompact），这里只负责
    // 把缩小后的那一侧裁出来。全程不重建 / 不 resize 平台视图。
    final compact = t > 0.5;
    // 角色在展开布局里位于**右侧**（操作栏在左），所以窄条要露出右侧，
    // 模型也必须靠到渲染视图的右侧并靠顶，否则露出的是一片空白。
    const compactSide = 'right';
    // 浮层没有 Material 祖先，必须给 DefaultTextStyle，
    // 否则文字会落到 Flutter 的 fallback 样式（红字 + 黄色双下划线）
    final textStyle = Theme.of(context).textTheme.bodyMedium ??
        const TextStyle(fontSize: 14, color: Colors.black87, height: 1.4);
    // 注意：这里**不能**用 Transform/AnimatedScale 做拖动/过渡反馈 ——
    // Android 的平台视图（WebView / TextureView）不支持任意变换，
    // 一旦被 transform 包裹就整块不渲染（表现成模型消失）。
    //
    // 外层尺寸跟着动画走（裁剪框），但**内层布局固定为展开尺寸** ——
    // 否则动画每帧都会 resize WebView，Android 平台视图每次 resize
    // 都要重建 surface，肉眼可见地卡。
    return DefaultTextStyle(
      style: textStyle,
      child: SizedBox(
        width: unitWidth,
        height: clipHeight,
        child: ClipRect(
          child: OverflowBox(
            // 紧凑时露出哪一块，取决于后端把模型放在视图的哪个位置：
            // - WebView：模型缩到窄条尺寸后靠右 → 露右侧（缩小版全身）
            // - 原生：canvas 有留白，缩放后无法精确对齐角色本体
            //   → 不缩放，露**顶部**（头 + 上半身完整可见，模型不会消失）
            alignment: !compact
                ? Alignment.topLeft
                : (link.avatarBackend == AvatarBackend.webview
                    ? Alignment.topRight
                    : Alignment.topCenter),
            // 内层保持**固定尺寸**：动画只改裁剪框，
            // 平台视图（WebView）不会被 resize
            minWidth: groupWidth,
            maxWidth: groupWidth,
            minHeight: contentH,
            maxHeight: contentH,
            child: SizedBox(
              width: groupWidth,
              height: contentH,
              // 用 Stack 而不是 Row：原生后端的 Live2DView 是混合合成的
              // 平台视图，**会忽略父约束而溢出**（Flutter 的裁剪对它无效），
              // 用 Row 时它会盖住左边的操作栏。改成 Stack 并把操作栏放在
              // 最后绘制（在上层）即可。
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  // 角色 + 话术框：左边留出操作栏的位置
                  Padding(
                    padding: const EdgeInsets.only(
                      left: FloatingAvatarHost.barWidth + FloatingAvatarHost.barGap,
                    ),
                    child: SizedBox(
                      width: groupWidth -
                          FloatingAvatarHost.barWidth -
                          FloatingAvatarHost.barGap,
                      child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        // 数字人本体：可拖动（translucent 保证点击仍能穿透到下层）
                        GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: compact ? _restoreFromDock : null,
                          onPanStart: (_) => setState(() => _dragging = true),
                          onPanUpdate: (d) => _onDragUpdate(link, free, d.delta),
                          onPanEnd: (_) => _onDragEnd(link, free),
                          onPanCancel: () => setState(() => _dragging = false),
                          child: SizedBox(
                            // 必须给固定宽度：放进 Row 后 Column 拿到的是无界宽度，
                            // Live2dAvatar 内部的 width: double.infinity 会变成无限宽导致渲染失败
                            width: double.infinity,
                            // 固定用展开态高度，避免动画期间 resize 平台视图
                            height: avatarH,
                            child: Live2dAvatar(
                              modelPath: link.avatarModel,
                              mouth: link.mouth,
                              height: avatarH,
                              // 贴边时让模型在视图内部缩小并靠到指定一侧
                              compact: compact,
                              compactSide: compactSide,
                              compactWidth: FloatingAvatarHost.dockedWidth,
                              compactHeight: FloatingAvatarHost.dockedHeight,
                            ),
                          ),
                        ),
                        // 紧凑（贴边）时窄条里放不下话术框
                        if (!link.bubbleCollapsed && !compact) ...<Widget>[
                          const SizedBox(height: 6),
                          AvatarBubble(
                            link: link,
                            maxHeight: FloatingAvatarHost.bubbleMaxHeight,
                          ),
                        ],
                      ],
                    ),
                    ),
                  ),
                  // 操作栏放在**最后**（Stack 里后画的在上层）——
                  // 原生的平台视图会溢出，必须压在上面才看得见
                  Positioned(
                    left: 0,
                    top: 0,
                    child: _buildArcBar(link, free, avatarH),
                  ),
                ],
              ),
            ),
          ),
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
        danger: true,
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
    final groupWidth = FloatingAvatarHost.groupWidth(media.size.width,
        modelAspect: PromptLink.instance.avatarModelAspect);
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
    final unitWidth = FloatingAvatarHost.groupWidth(media.size.width,
        modelAspect: PromptLink.instance.avatarModelAspect);
    // 靠近左右边缘 -> 自动贴边收起
    final nearLeft = pos.dx <= FloatingAvatarHost.dockThreshold;
    final nearRight = (media.size.width - (pos.dx + unitWidth)) <= FloatingAvatarHost.dockThreshold;
    if (nearLeft || nearRight) {
      setState(() {
        _docked = true;
        _dockRight = nearRight && !nearLeft;
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
    final center = currentLeft +
        FloatingAvatarHost.groupWidth(media.size.width,
            modelAspect: PromptLink.instance.avatarModelAspect) /
            2;
    setState(() {
      _dockRight = center > media.size.width / 2;
      _docked = true;
    });
  }

  Future<void> _persistPosition({required Size free}) async {
    final pos = _dragPos;
    if (pos == null) return;
    final normalized = AvatarLayout.normalize(pos, free);
    await PromptLink.instance.setAvatarPosition(normalized.dx, normalized.dy);
  }
}


  /// 贴边时的「展开」按钮（Flutter 绘制，不受平台视图挡触摸的影响）
  class _ExpandChip extends StatelessWidget {
    const _ExpandChip({required this.onTap});

    final VoidCallback onTap;

    @override
    Widget build(BuildContext context) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: const Color(0xFF2F6BFF).withValues(alpha: 0.92),
            shape: BoxShape.circle,
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: const Icon(
            Icons.open_in_full_rounded,
            size: 16,
            color: Colors.white,
          ),
        ),
      );
    }
  }

