import 'package:material_ui/material_ui.dart';

import '../services/avatar_renderer.dart';
import '../services/prompt_link.dart';
import 'app_toast.dart';
import 'arc_action_bar.dart';
import '../utils/avatar_layout.dart';
import 'avatar_stage.dart';
import 'live2d_avatar.dart';
import 'model_picker_sheet.dart';

/// 全局浮动的 Live2D 数字人：
/// - 展开态：上半部分是「角色 + 右侧操作栏」，下半部分是话术框（宽度与上方对齐，可单独收起）
/// - 贴边态：像微信通话「最小化」一样缩到屏幕边缘，只留一个小挂件，点击或拖动即恢复
///
/// 说明：Live2D 用 WebView（平台视图）渲染。平台视图上已加 IgnorePointer，
/// 因此角色区域/状态/话术框的点击都会穿透到下面的页面，只有操作栏和挂件按钮可交互。
class FloatingAvatarHost extends StatefulWidget {
  const FloatingAvatarHost({super.key, required this.child});

  final Widget child;

  /// 弧形操作栏宽度（月亮型，图标点击区 + 弧线外扩空间）
  static const double barWidth = ArcActionBar.barWidth;

  /// 贴边时（缩小）尺寸
  static const double dockedWidth = 96;
  static const double dockedHeight = 152;

  /// 角色盒与操作栏之间的间距
  ///
  /// **负值** = 让月牙压住角色盒边缘：弧的凹面朝角色、两端本来就更贴近轮廓，
  /// 压进去几个像素视觉上是「包住」而不是「并排」，比留 8px 空隙紧凑得多。
  /// 布局里 `padL = barWidth + barGap`，负值天然支持（角色向左多占几像素）。
  static const double barGap = -4;

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
  /// 瘦高模型（如 Haru ≈0.45）按真实比例只有 180 宽，这里托底到 208，
  /// 模型在框内居中 —— 左右留白对称，不会再出现「只有一边空一大片」。
  ///
  /// 从 232 收到 208：配合操作栏收窄，整组宽度能再省 24px；提词框仍够放
  /// 十来个字一行（12px 字号下约 17 字）。
  static const double minAvatarBoxWidth = 208;

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
                      // 拖动中**禁用位置动画**：每次手指移动都会重启一个
                      // 240ms 的位移动画，浮窗永远在追手指 → 看起来「不灵敏」。
                      // 松手后（或贴边切换）才用动画。
                      duration: _dragging
                          ? Duration.zero
                          : const Duration(milliseconds: 240),
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
    // 贴边进度：过一半后进入「紧凑模式」。
    final compact = t > 0.5;
    // 动态宽高：贴边时把平台视图**直接 resize 到窄条尺寸**，后端对「整个视口」
    // 做居中 contain（见 C++ ApplyViewportFit / index.html fit），不再裁角、不
    // 依赖出屏溢出 —— 左右贴边天然对称、身体完整。展开时内层是整组尺寸。
    final double dockW = FloatingAvatarHost.dockedWidth;
    final double dockH = FloatingAvatarHost.dockedHeight;
    final double outerW = compact ? dockW : unitWidth;
    final double outerH = compact ? dockH : clipHeight;
    final double innerW = compact ? dockW : groupWidth;
    final double innerH = compact ? dockH : contentH;
    final double padL = compact
        ? 0.0
        : FloatingAvatarHost.barWidth + FloatingAvatarHost.barGap;
    final double boxW = compact
        ? dockW
        : groupWidth - FloatingAvatarHost.barWidth - FloatingAvatarHost.barGap;
    final double boxH = compact ? dockH : avatarH;
    // 拖动手势热区宽度：展开时≈角色本体宽（两侧留白仍可穿透），贴边时=整条窄条
    final double effAspect = PromptLink.instance.avatarModelAspect > 0
        ? PromptLink.instance.avatarModelAspect.clamp(
            FloatingAvatarHost.minAvatarAspect,
            FloatingAvatarHost.maxAvatarAspect)
        : FloatingAvatarHost.defaultAvatarAspect;
    final double dragW = compact
        ? boxW
        : (boxH * effAspect * 1.2).clamp(90.0, boxW);
    // 浮层没有 Material 祖先，必须给 DefaultTextStyle，
    // 否则文字会落到 Flutter 的 fallback 样式（红字 + 黄色双下划线）
    final textStyle = Theme.of(context).textTheme.bodyMedium ??
        const TextStyle(fontSize: 14, color: Colors.black87, height: 1.4);
    // 注意：这里**不能**用 Transform/AnimatedScale 做拖动/过渡反馈 ——
    // Android 的平台视图（WebView / TextureView）不支持任意变换，
    // 一旦被 transform 包裹就整块不渲染（表现成模型消失）。
    //
    // widget 树的类型/层级在展开与紧凑之间保持一致（只改尺寸/参数），保证
    // Live2dAvatar 只被 resize、不被 remount（否则平台视图重建、模型重载闪断）。
    return DefaultTextStyle(
      style: textStyle,
      child: SizedBox(
        width: outerW,
        height: outerH,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: innerW,
            maxWidth: innerW,
            minHeight: innerH,
            maxHeight: innerH,
            child: SizedBox(
              width: innerW,
              height: innerH,
              // 用 Stack：原生后端的 Live2DView 是混合合成平台视图，会忽略
              // Flutter 的裁剪，操作栏放在最后绘制（上层）才不会被盖住。
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  // 角色 + 话术框：展开时左边留操作栏位置；贴边时贴左缘
                  Padding(
                    padding: EdgeInsets.only(left: padL),
                    child: SizedBox(
                      width: boxW,
                      child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        // 数字人本体：
                        // - 渲染层占满角色盒（平台视图本身透明命中，不拦点击）
                        // - 叠一个**只覆盖角色本体宽度**的 opaque 拖动热区：
                        //   opaque 才能在手势竞技场里赢过下层页面的滚动（translucent
                        //   会和页面抢 → 拖动“不灵敏/穿透”）；热区收窄到角色宽度，
                        //   两侧留白仍可穿透到下层页面。
                        SizedBox(
                          width: double.infinity,
                          height: boxH,
                          child: Stack(
                            alignment: Alignment.center,
                            children: <Widget>[
                              Live2dAvatar(
                                modelPath: link.avatarModel,
                                mouth: link.mouth,
                                height: boxH,
                                // 靠 resize 视图适配贴边，后端不再做「缩小贴角」
                                compact: false,
                                compactSide: 'right',
                                compactWidth: dockW,
                                compactHeight: dockH,
                              ),
                              // 透明但 opaque 的热区：只负责拖动/点击，不画任何东西
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: compact ? _restoreFromDock : null,
                                onPanStart: (_) => setState(() => _dragging = true),
                                onPanUpdate: (d) => _onDragUpdate(link, free, d.delta),
                                onPanEnd: (_) => _onDragEnd(link, free),
                                onPanCancel: () => setState(() => _dragging = false),
                                child: SizedBox(width: dragW, height: boxH),
                              ),
                            ],
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
                  // 操作栏：贴边时不显示（窄条放不下，动态 resize 也不再需要裁角避让）
                  if (!compact)
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
      // 立即播报：和顶部快捷条那个按钮等价，放在操作栏最上面方便单手按
      ArcAction(
        icon: Icons.campaign_outlined,
        tooltip: '立即播报',
        onTap: () {
          // 浮窗只在手机端出现：没连播放端、本机也不是播放端时，
          // 广播出去没人会念（同一 Wi-Fi 多台设备时尤其容易误判）
          if (!link.peerConnected && !link.asPlayer) {
            AppToast.error(
              context,
              '还没有连接播放端：请在「连接」页点「扫描设备」选择',
            );
            return;
          }
          // 只有双角色（本机自己播）才需要本机有音频；
          // 只当拨号端时音频在播放端那台，这里不需要
          if (link.asPlayer && !link.hasAudio) {
            AppToast.error(context, '请先添加开场白音频（选择 / 生成 / 录制）');
            return;
          }
          link.triggerManually();
        },
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
        icon: Icons.face_retouching_natural,
        tooltip: '切换模型',
        onTap: () => _pickModelFloating(),
      ),
      ArcAction(
        icon: link.avatarBackend == AvatarBackend.native
            ? Icons.memory
            : Icons.public,
        tooltip: link.avatarBackend == AvatarBackend.native
            ? '渲染引擎：原生（点按切到 WebView）'
            : '渲染引擎：WebView（点按切到原生）',
        onTap: () => _toggleBackend(),
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
    // 退出紧凑模式，恢复完整尺寸
    link.setAvatarCompact(false);
  }

  /// 悬浮操作栏：弹出模型选择器切换当前数字人模型
  Future<void> _pickModelFloating() async {
    final link = PromptLink.instance;
    final models = await link.availableAvatarModels();
    if (!mounted) return;
    final chosen = await ModelPickerSheet.show(context, link: link, models: models);
    if (chosen == null || !mounted) return;
    await link.setAvatarModel(chosen);
  }

  /// 悬浮操作栏：在 WebView / 原生之间切换渲染后端（平台不支持则提示）
  Future<void> _toggleBackend() async {
    final link = PromptLink.instance;
    final target = link.avatarBackend == AvatarBackend.native
        ? AvatarBackend.webview
        : AvatarBackend.native;
    final reason = backendUnsupportedReason(target);
    if (reason != null) {
      if (mounted) AppToast.error(context, reason);
      return;
    }
    await link.setAvatarBackend(target);
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
      // 通知后端进入紧凑模式（模型在视图内部缩小）
      PromptLink.instance.setAvatarCompact(
        true,
        side: 'right',
        width: FloatingAvatarHost.dockedWidth,
        height: FloatingAvatarHost.dockedHeight,
      );
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
    // 通知后端：把模型在视图内部缩小到窄条大小（不重建视图）
    link.setAvatarCompact(
      true,
      side: 'right',
      width: FloatingAvatarHost.dockedWidth,
      height: FloatingAvatarHost.dockedHeight,
    );
  }

  Future<void> _persistPosition({required Size free}) async {
    final pos = _dragPos;
    if (pos == null) return;
    final normalized = AvatarLayout.normalize(pos, free);
    await PromptLink.instance.setAvatarPosition(normalized.dx, normalized.dy);
  }
}



