import 'package:flutter/material.dart';

import '../services/prompt_link.dart';
import 'app_toast.dart';
import 'avatar_stage.dart';
import 'model_picker_sheet.dart';

/// 桌面端分栏布局：左边数字人舞台，右边主操作界面。
///
/// 桌面端不再用「浮窗叠加」的方式展示数字人 —— WebView2 是原生控件，
/// 浮在 Flutter 内容上时会出现透明/裁剪/贴边等各种问题（Windows 尤其明显）。
/// 改成固定分栏后，数字人就是普通布局的一部分，行为与手机端一致且稳定。
class DesktopSplitView extends StatelessWidget {
  const DesktopSplitView({super.key, required this.child});

  /// 右侧的主界面
  final Widget child;

  /// 左栏占窗口宽度的比例（2/5）
  static const double panelRatio = 0.4;

  /// 左栏最小宽度
  static const double minPanelWidth = 260;

  /// 左栏最大宽度
  static const double maxPanelWidth = 640;

  /// 数字人区域占左栏高度的比例
  static const double avatarHeightRatio = 0.5;

  /// 提词气泡占左栏高度的比例
  static const double bubbleHeightRatio = 0.3;

  /// 按钮区占左栏高度的比例
  static const double actionHeightRatio = 0.2;

  @override
  Widget build(BuildContext context) {
    final link = PromptLink.instance;
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            // 左栏固定为窗口宽度的 2/5
            final panelWidth = (constraints.maxWidth * panelRatio)
                .clamp(minPanelWidth, maxPanelWidth)
                .toDouble();
            // 必须有 Material 祖先：左栏用了 Switch / BottomSheet 等 Material 组件
            return Material(
              type: MaterialType.transparency,
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: panelWidth,
                    child: _AvatarPanel(link: link, panelWidth: panelWidth),
                  ),
                  const VerticalDivider(width: 1, thickness: 1, color: Color(0xFFE3E8F0)),
                  Expanded(child: child),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// 左边的数字人面板
class _AvatarPanel extends StatelessWidget {
  const _AvatarPanel({required this.link, required this.panelWidth});

  final PromptLink link;
  final double panelWidth;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: panelWidth,
      color: const Color(0xFFF7F9FC),
      child: Column(
        children: <Widget>[
          _panelHeader(context),
          Expanded(
            // 高度按比例分配：数字人 50% / 气泡 30% / 按钮区 20%
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // 数字人本体（50%）
                  Expanded(
                    flex: 50,
                    child: LayoutBuilder(
                      builder: (context, constraints) => Container(
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
                                avatarHeight: constraints.maxHeight,
                                showBubble: false,
                                avatarBoxWidth: panelWidth - 32,
                              )
                            : const _AvatarOffHint(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 提词气泡（30%）
                  Expanded(
                    flex: 30,
                    child: LayoutBuilder(
                      builder: (context, constraints) => AvatarBubble(
                        link: link,
                        maxHeight: constraints.maxHeight,
                        solid: true,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 按钮区（20%）：上一步 / 下一步 / 切换模型
                  Expanded(
                    flex: 20,
                    child: _ActionArea(link: link),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 面板顶部：标题 + 开关
  Widget _panelHeader(BuildContext context) {
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
        const Text('数字人未开启', style: TextStyle(fontSize: 13, color: Colors.black38)),
        const SizedBox(height: 2),
        const Text('打开上方开关即可显示', style: TextStyle(fontSize: 11, color: Colors.black26)),
      ],
    );
  }
}

/// 按钮区：上一步 / 下一步 / 切换模型
class _ActionArea extends StatelessWidget {
  const _ActionArea({required this.link});

  final PromptLink link;

  @override
  Widget build(BuildContext context) {
    final steps = link.scriptSteps;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Row(
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
        ),
        const SizedBox(height: 10),
        // 切换模型：放在按钮区，保证始终可见（之前放在最底部会被挤到视口外）
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () async {
              final models = await link.availableAvatarModels();
              if (!context.mounted) return;
              if (models.isEmpty) {
                AppToast.error(context, '没有可用模型');
                return;
              }
              final chosen = await ModelPickerSheet.show(context, link: link, models: models);
              if (chosen == null || !context.mounted) return;
              await link.setAvatarModel(chosen);
            },
            icon: const Icon(Icons.swap_horiz, size: 18),
            label: const Text('切换模型', style: TextStyle(fontSize: 13)),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(40)),
          ),
        ),
      ],
    );
  }
}

