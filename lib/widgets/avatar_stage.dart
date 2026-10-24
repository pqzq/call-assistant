import 'package:flutter/material.dart';

import '../models/active_lead.dart';
import '../services/avatar_renderer.dart';
import '../services/prompt_link.dart';
import 'glass_surface.dart';
import 'live2d_avatar.dart';

/// 数字人舞台：Live2D 角色 + 提词气泡。
///
/// 手机端用它在**浮窗**里展示，桌面端用它在**左侧分栏**里展示，
/// 两边共用同一套渲染逻辑，避免重复实现。
class AvatarStage extends StatelessWidget {
  const AvatarStage({
    super.key,
    required this.link,
    this.avatarHeight = 220,
    this.showBubble = true,
    this.bubbleMaxHeight = 150,
    this.solidBubble = false,
    this.avatarBoxWidth,
    this.backend,
  });

  final PromptLink link;

  /// 数字人区域高度
  final double avatarHeight;

  /// 是否显示提词气泡
  final bool showBubble;

  /// 气泡最大高度
  final double bubbleMaxHeight;

  /// 气泡用实心背景（桌面分栏里用，避免和半透明叠在一起看不清）
  final bool solidBubble;

  /// 数字人区域宽度（不传则自适应）
  final double? avatarBoxWidth;

  /// 渲染后端（不传则用 link 的当前值；显式传入是为了切换时能重建 renderer）
  final AvatarBackend? backend;

  @override
  Widget build(BuildContext context) {
    // 不显示气泡时只放角色本身：
    // 多包一层 Column 会因为 SizedBox 的高度与父约束差几个像素而溢出
    if (!showBubble) {
      return SizedBox(
        width: avatarBoxWidth,
        height: avatarHeight,
        child: Live2dAvatar(
          modelPath: link.avatarModel,
          mouth: link.mouth,
          height: avatarHeight,
            backend: backend ?? link.avatarBackend,
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: avatarBoxWidth,
          height: avatarHeight,
          child: Live2dAvatar(
            modelPath: link.avatarModel,
            mouth: link.mouth,
            height: avatarHeight,
            backend: backend ?? link.avatarBackend,
          ),
        ),
        if (!link.bubbleCollapsed) ...<Widget>[
          const SizedBox(height: 8),
          AvatarBubble(
            link: link,
            maxHeight: bubbleMaxHeight,
            solid: solidBubble,
          ),
        ],
      ],
    );
  }
}

/// 提词气泡：状态 + 当前客户 + 话术提词
class AvatarBubble extends StatelessWidget {
  const AvatarBubble({
    super.key,
    required this.link,
    this.maxHeight = 150,
    this.solid = false,
  });

  final PromptLink link;
  final double maxHeight;

  /// 实心背景（桌面端用）
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final lead = link.activeLead;
    final steps = link.scriptSteps;
    final step = link.currentStep;
    final status = link.avatarStatus;
    // 纯展示：整体不可命中，避免挡住下面的内容
    return IgnorePointer(
      child: _bubbleShell(
        maxHeight: maxHeight,
        solid: solid,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _StatusLine(status: status, lead: lead),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
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
                        color: lead.lastCalled == null
                            ? const Color(0xFF17A05A)
                            : Colors.black38,
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
                const SizedBox(height: 5),
                Text(
                  '话术 ${link.stepIndex + 1}/${steps.length}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2F6BFF),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  step,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, height: 1.4, color: Colors.black87),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

  /// 话术框外壳
  ///
  /// - 手机浮窗（solid = false）：**液态玻璃**，模糊下层页面，文字仍然清晰
  /// - 桌面分栏（solid = true）：实心白底，避免和分栏背景叠色影响阅读
  Widget _bubbleShell({
    required double maxHeight,
    required bool solid,
    required Widget child,
  }) {
    if (solid) {
      return Container(
        width: double.infinity,
        constraints: BoxConstraints(maxHeight: maxHeight),
        padding: const EdgeInsets.fromLTRB(11, 8, 11, 8),
        decoration: BoxDecoration(
          color: Colors.white,
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
        child: child,
      );
    }
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: GlassSurface(
        borderRadius: 18,
        blur: 32,
        opacity: 0.42,
        padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
        child: child,
      ),
    );
  }
/// 状态行：状态圆点 + 状态文案 + 当前客户名
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.status, required this.lead});

  final AvatarStatus status;
  final ActiveLead? lead;

  @override
  Widget build(BuildContext context) {
    final color = avatarStatusColor(status);
    return Row(
      children: <Widget>[
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          status.label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
        if (lead != null) ...<Widget>[
          const SizedBox(width: 6),
          const Text('·', style: TextStyle(fontSize: 12, color: Colors.black26)),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 130),
            child: Text(
              lead!.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
        ],
      ],
    );
  }
}

/// 状态对应的颜色（浮窗与分栏共用）
Color avatarStatusColor(AvatarStatus status) {
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
