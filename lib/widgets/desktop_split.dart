import 'package:material_ui/material_ui.dart';

import 'glass_surface.dart';
import 'page_title.dart';

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
        // 左右**各占一半**：两边都用 Expanded 均分，窗口怎么缩放都严格对半。
        // （分隔线占 1px，两边各少 0.5px，可忽略）
        //
        // 必须有 Material 祖先：左栏用了 Switch / BottomSheet 等 Material 组件
        return Material(
          type: MaterialType.transparency,
          child: Row(
            children: <Widget>[
              Expanded(
                // 左栏宽度由 Expanded 决定，这里读**真实约束**再传下去：
                // 数字人盒宽是 panelWidth - 32，拿不到实际宽度会算错
                child: LayoutBuilder(
                  builder: (context, panelConstraints) => _AvatarPanel(
                    link: link,
                    panelWidth: panelConstraints.maxWidth,
                  ),
                ),
              ),
              const VerticalDivider(
                width: 1,
                thickness: 1,
                color: Color(0xFFE3E8F0),
              ),
              Expanded(child: child),
            ],
          ),
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
      // 浅蓝渐变底：和右栏同一套，玻璃卡片才有东西可透
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Color(0xFFEDF2FE),
            Color(0xFFF7F9FC),
            Color(0xFFF1F5FF),
          ],
        ),
      ),
      child: Stack(
        children: <Widget>[
          Column(
            children: <Widget>[
              _panelHeader(context),
              Expanded(
                // 底部留出悬浮玻璃条的位置（86 = 条高 + 上下留白）
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 86),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      // 数字人本体（60%）
                      Expanded(
                        flex: 60,
                        child: LayoutBuilder(
                          builder: (context, constraints) => Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.72),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.9),
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            alignment: Alignment.center,
                            child: !link.avatarEnabled
                                ? const _AvatarOffHint()
                                // 演示页是全屏数字人，会 setSuppressAvatar(true)。
                                // 左栏这份**必须卸载**：两个 Live2dAvatar 同时存在时，
                                // Windows 插件是单实例（create 会先销毁上一个并注销它的
                                // 纹理），后建的那个会把先建的顶掉 —— 表现为左栏数字人
                                // 变窄/空白/消失。浮窗侧早就在检查这个标志，左栏漏了。
                                : (link.suppressAvatar
                                    ? const SizedBox.shrink()
                                    : AvatarStage(
                                        link: link,
                                        avatarHeight: constraints.maxHeight,
                                        showBubble: false,
                                        avatarBoxWidth: panelWidth - 32,
                                      )),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // 提词气泡（40%）
                      Expanded(
                        flex: 40,
                        child: LayoutBuilder(
                          builder: (context, constraints) => AvatarBubble(
                            link: link,
                            maxHeight: constraints.maxHeight,
                            solid: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          // 底部悬浮玻璃条：一行按钮，和右栏 GlassNavBar 同一套材质/位置
          Positioned(
            left: 16,
            right: 16,
            bottom: 14,
            child: GlassNavBar(child: _ActionArea(link: link)),
          ),
        ],
      ),
    );
  }

  /// 面板顶部：标题 + 当前模型 + 开关，**全部压在一行**（56，与右栏 AppBar 同高）
  ///
  /// 开关和模型名原来在下面一个 98 高的玻璃块里，占掉不少纵向空间；
  /// 合并进标题栏后，数字人区域多出约 100px。
  Widget _panelHeader(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
        child: Row(
          children: <Widget>[
            const Icon(Icons.face_retouching_natural,
                size: 18, color: Color(0xFF2F6BFF)),
            const SizedBox(width: 8),
            const Text('数字人', style: kPageTitleStyle),
            const SizedBox(width: 8),
            // 当前模型：小字灰，占剩余宽度，长了省略
            Expanded(
              child: Text(
                link.avatarModel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.black54),
              ),
            ),
            Switch(
              value: link.avatarEnabled,
              onChanged: (v) => link.setAvatarEnabled(v),
            ),
          ],
        ),
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
        const Text('数字人未开启', style: TextStyle(fontSize: 13, color: Colors.black54)),
        const SizedBox(height: 2),
        const Text('打开上方开关即可显示', style: TextStyle(fontSize: 11, color: Colors.black54)),
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
    // 一行三个项，视觉语言与右栏底部 GlassNavItem 一致（图标 + 11px 文字）。
    // 外层已经是 GlassNavBar，这里只排内容。
    return Row(
      children: <Widget>[
        Expanded(
          child: _item(
            icon: Icons.chevron_left,
            label: '上一步',
            enabled: link.stepIndex > 0,
            onTap: link.previousStep,
          ),
        ),
        Expanded(
          child: _item(
            icon: Icons.chevron_right,
            label: '下一步',
            enabled: link.stepIndex < steps.length - 1,
            onTap: link.nextStep,
          ),
        ),
        Expanded(
          child: _item(
            icon: Icons.swap_horiz,
            label: '切模型',
            enabled: true,
            onTap: () async {
              final models = await link.availableAvatarModels();
              if (!context.mounted) return;
              if (models.isEmpty) {
                AppToast.error(context, '没有可用模型');
                return;
              }
              final chosen = await ModelPickerSheet.show(context,
                  link: link, models: models);
              if (chosen == null || !context.mounted) return;
              await link.setAvatarModel(chosen);
            },
          ),
        ),
      ],
    );
  }

  /// 一个按钮项：图标 + 短文字（和右栏 GlassNavItem 同一视觉语言）
  Widget _item({
    required IconData icon,
    required String label,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final color = enabled ? const Color(0xFF2F6BFF) : const Color(0xFFB6BECC);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 19, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

