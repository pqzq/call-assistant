import 'package:flutter/material.dart';

import 'glass_surface.dart';

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
      // 与右栏（Scaffold 背景）一致，两栏底色不再有分界感
      color: const Color(0xFFF4F6FB),
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

  /// 面板顶部：标题 + 开关 + 后端/模型信息
  ///
  /// 用 minHeight 96 而不是固定高度：右栏顶部是「角色胶囊 + 立即播报」两行
  /// （8 + 32 + 8 + 40 + 8 = 96），这里撑到同高，**两栏顶部边界对齐**成一条横线，
  /// 内容超高也不会溢出。
  Widget _panelHeader(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 96),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE3E8F0))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.face_retouching_natural,
                  size: 18, color: Color(0xFF2F6BFF)),
              const SizedBox(width: 8),
              const Text('数字人',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const Spacer(),
              Switch(
                value: link.avatarEnabled,
                onChanged: (v) => link.setAvatarEnabled(v),
              ),
            ],
          ),
          // 第二行：渲染后端 + 当前模型（填充高度，顶部信息也更完整）
          Text(
            '${link.avatarBackend.displayName} · ${link.avatarModel}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Colors.black54),
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
    // 用和右栏底部 GlassNavBar 同一套参数（圆角 24 / blur 24 / opacity 0.82），
    // 两栏底部看起来是同一个材质的悬浮玻璃块。
    return GlassSurface(
      borderRadius: 20,
      blur: 24,
      opacity: 0.82,
      padding: const EdgeInsets.all(10),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: link.stepIndex > 0 ? link.previousStep : null,
                  icon: const Icon(Icons.chevron_left, size: 18),
                  label: const Text('上一步', style: TextStyle(fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(38)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: link.stepIndex < steps.length - 1
                      ? link.nextStep
                      : null,
                  icon: const Icon(Icons.chevron_right, size: 18),
                  label: const Text('下一步', style: TextStyle(fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(38)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
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
                final chosen = await ModelPickerSheet.show(context,
                    link: link, models: models);
                if (chosen == null || !context.mounted) return;
                await link.setAvatarModel(chosen);
              },
              icon: const Icon(Icons.swap_horiz, size: 18),
              label: const Text('切换模型', style: TextStyle(fontSize: 13)),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(38)),
            ),
          ),
        ],
      ),
    );
  }
}

