import 'package:flutter/material.dart';

import '../services/app_navigator.dart';
import '../services/live2d_service.dart';
import '../services/prompt_link.dart';
import 'app_toast.dart';
import 'confirm_dialog.dart';

/// 数字人模型选择弹窗（手机端「切换模型」与桌面左栏共用）
///
/// - 展示所有可用模型（内置 + 用户导入）
/// - 用户自己导入的模型带删除按钮，内置模型不提供删除
class ModelPickerSheet {
  const ModelPickerSheet._();

  /// 是否已经有一个选择器在屏幕上
  ///
  /// 连点「切换模型」会叠出多个 bottom sheet（手机浮窗和桌面分栏都有这个
  /// 入口）。用静态标记挡住重复调用 —— 所有入口共用这一个守卫，
  /// 不用在每个按钮上各写一遍防抖。
  static bool _visible = false;

  /// 打开模型选择弹窗，返回选中的模型（取消返回 null）
  static Future<String?> show(
    BuildContext context, {
    required PromptLink link,
    required List<String> models,
  }) async {
    if (models.isEmpty) {
      AppToast.error(context, '没有可用模型');
      return null;
    }
    if (_visible) return null; // 已经有弹窗在显示，忽略重复点击
    // 桌面端分栏在 Navigator 之外，必须用全局 navigator 弹
    final navigator = resolveNavigator(context);
    if (navigator == null) return null;
    _visible = true;
    try {
      return await showModalBottomSheet<String>(
        context: navigator.context,
        showDragHandle: true,
        builder: (sheetContext) => _ModelList(
          link: link,
          models: models,
          onChanged: () async {
            // 刷新列表（删除模型后重新拉一次）
            final rest = await link.availableAvatarModels();
            if (!sheetContext.mounted) return;
            final navigator = Navigator.of(sheetContext);
            navigator.pop();
            if (rest.isEmpty) return;
            // 等当前弹窗真正关闭、_visible 复位后再重开（关闭动画 250ms），
            // 否则这次重开会被上面的防连点守卫挡住，表现为「删完模型列表不刷新」
            await Future<void>.delayed(const Duration(milliseconds: 350));
            if (!context.mounted) return;
            show(context, link: link, models: rest);
          },
        ),
      );
    } finally {
      _visible = false;
    }
  }
}

class _ModelList extends StatelessWidget {
  const _ModelList({
    required this.link,
    required this.models,
    required this.onChanged,
  });

  final PromptLink link;
  final List<String> models;
  final Future<void> Function() onChanged;

  /// 模型展示名（去掉路径与后缀）
  static String labelOf(String model) {
    final file = model.split('/').last;
    final lower = file.toLowerCase();
    if (lower.endsWith('.model3.json')) {
      return file.substring(0, file.length - '.model3.json'.length);
    }
    final dot = file.lastIndexOf('.');
    return dot > 0 ? file.substring(0, dot) : file;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('选择数字人模型', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          for (final model in models)
            ListTile(
              title: Text(labelOf(model), maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                model,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.black38),
              ),
              trailing: model == link.avatarModel
                  ? const Icon(Icons.check, size: 18)
                  : (Live2dService.isUserImported(model)
                      // 用户自己导入的模型可以移除，内置的不提供移除
                      ? IconButton(
                          tooltip: '移除这个模型',
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () async {
                            final navigator = Navigator.of(context);
                            final ok = await _confirmDelete(context, model);
                            if (ok != true || !context.mounted) return;
                            await link.deleteAvatarModel(model);
                            if (!context.mounted) return;
                            await onChanged();
                            if (!context.mounted) return;
                            navigator.pop();
                            AppToast.show(context, '已移除模型');
                          },
                        )
                      : null),
              onTap: () => Navigator.of(context).pop(model),
            ),
        ],
      ),
    );
  }

  /// 删除确认（只允许删用户导入的模型）
  static Future<bool> _confirmDelete(BuildContext context, String model) {
    return ConfirmDialog.show(
      context,
      title: '移除模型',
      message: '确定移除「${labelOf(model)}」吗？\n该模型占用的文件会一并删除。',
      confirmText: '移除',
      destructive: true,
      icon: Icons.delete_outline,
    );
  }
}
