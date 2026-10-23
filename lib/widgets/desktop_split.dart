import 'package:flutter/material.dart';

import '../services/prompt_link.dart';
import 'avatar_stage.dart';

/// 桌面端分栏布局：左边数字人舞台，右边主操作界面。
///
/// 桌面端不再用「浮窗叠加」的方式展示数字人 —— WebView2 是原生控件，
/// 浮在 Flutter 内容上时会出现透明/裁剪/贴边等各种问题（Windows 尤其明显）。
/// 改成固定分栏后，数字人就是普通布局的一部分，行为与手机端一致且稳定。
class DesktopSplitView extends StatelessWidget {
  const DesktopSplitView({super.key, required this.child});

  /// 右侧的主界面
  final Widget child;

  /// 左栏默认宽度
  static const double panelWidth = 360;

  /// 左栏最小宽度
  static const double minPanelWidth = 260;

  @override
  Widget build(BuildContext context) {
    final link = PromptLink.instance;
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) {
        return Row(
          children: <Widget>[
            _AvatarPanel(link: link),
            const VerticalDivider(width: 1, thickness: 1, color: Color(0xFFE3E8F0)),
            Expanded(child: child),
          ],
        );
      },
    );
  }
}

/// 左边的数字人面板
class _AvatarPanel extends StatelessWidget {
  const _AvatarPanel({required this.link});

  final PromptLink link;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = DesktopSplitView.panelWidth;
    // 数字人区域高度：跟随窗口高度，留出上下空间
    final media = MediaQuery.of(context);
    final avatarHeight = (media.size.height * 0.52).clamp(220.0, 520.0);

    return Container(
      width: width,
      color: const Color(0xFFF7F9FC),
      child: Column(
        children: <Widget>[
          _panelHeader(theme),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // 数字人本体
                  Container(
                    height: avatarHeight,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE3E8F0)),
                    ),
                    clipBehavior: Clip.antiAlias,
                    alignment: Alignment.center,
                    child: link.avatarEnabled
                        ? AvatarStage(
                            link: link,
                            avatarHeight: avatarHeight,
                            showBubble: false,
                            avatarBoxWidth: width - 32,
                          )
                        : const _AvatarOffHint(),
                  ),
                  const SizedBox(height: 12),
                  // 提词气泡
                  AvatarBubble(
                    link: link,
                    maxHeight: 220,
                    solid: true,
                  ),
                  const SizedBox(height: 12),
                  _ActionRow(link: link),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 面板顶部：标题 + 开关
  Widget _panelHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE3E8F0))),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.face_retouching_natural, size: 18, color: Color(0xFF2F6BFF)),
          const SizedBox(width: 8),
          const Text('数字人', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const Spacer(),
          Switch(
            value: link.avatarEnabled,
            onChanged: (v) => link.setAvatarEnabled(v),
          ),
        ],
      ),
    );
  }
}

/// 数字人未开启时的占位
class _AvatarOffHint extends StatelessWidget {
  const _AvatarOffHint();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Icon(Icons.face_retouching_natural, size: 40, color: Colors.black.withValues(alpha: 0.18)),
        const SizedBox(height: 10),
        const Text(
          '数字人未开启',
          style: TextStyle(fontSize: 13, color: Colors.black38),
        ),
        const SizedBox(height: 2),
        const Text(
          '打开上方开关即可显示',
          style: TextStyle(fontSize: 11, color: Colors.black26),
        ),
      ],
    );
  }
}

/// 话术上下步 + 气泡收起
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.link});

  final PromptLink link;

  @override
  Widget build(BuildContext context) {
    final steps = link.scriptSteps;
    return Row(
      children: <Widget>[
        Expanded(
          child: OutlinedButton.icon(
            onPressed: link.stepIndex > 0 ? link.previousStep : null,
            icon: const Icon(Icons.chevron_left, size: 18),
            label: const Text('上一步', style: TextStyle(fontSize: 13)),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(40)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: link.stepIndex < steps.length - 1 ? link.nextStep : null,
            icon: const Icon(Icons.chevron_right, size: 18),
            label: const Text('下一步', style: TextStyle(fontSize: 13)),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(40)),
          ),
        ),
      ],
    );
  }
}
