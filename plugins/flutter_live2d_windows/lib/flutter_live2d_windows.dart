import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Windows 原生 Live2D 渲染插件（纹理路线）。
///
/// C++ 侧在独立渲染线程离屏渲染，逐帧以 RGBA 像素缓冲推给 Flutter 合成。
/// M0 已打通：create/setSize/dispose + 纹理逐帧刷新；
/// M1 将补：loadModel/setParameter/startMotion。
const MethodChannel _kChannel = MethodChannel('flutter_live2d_windows');

/// 一个 Live2D 渲染实例的控制器，与一个纹理 id 一一对应。
class WindowsLive2DController extends ChangeNotifier {
  int? _textureId;
  bool _disposed = false;

  /// 引擎侧纹理 id；create 成功后有效。
  int? get textureId => _textureId;

  /// 创建渲染实例与纹理。[width]/[height] 用**物理像素**（逻辑尺寸 × dpr）。
  Future<int?> create({required double width, required double height}) async {
    assert(!_disposed, 'controller already disposed');
    if (_textureId != null) return _textureId;
    final id = await _kChannel.invokeMethod<int>(
      'create',
      <String, double>{'width': width, 'height': height},
    );
    _textureId = id;
    notifyListeners();
    return id;
  }

  /// 尺寸变化（物理像素），不重建纹理。
  Future<void> setSize({required double width, required double height}) {
    return _kChannel.invokeMethod<void>(
      'setSize',
      <String, double>{'width': width, 'height': height},
    );
  }

  /// 加载模型。[dir] 为模型目录绝对路径（含结尾分隔符也可省略），
  /// [file] 为 *.model3.json 文件名。异步执行，完成后纹理自动切换为模型画面。
  Future<bool> loadModel({required String dir, required String file}) async {
    final ok = await _kChannel.invokeMethod<bool>(
      'loadModel',
      <String, Object>{'dir': dir, 'file': file},
    );
    return ok ?? false;
  }

  /// 设置模型参数（如嘴型 ParamMouthOpenY，0~1）。
  Future<void> setParameter(String id, double value) {
    return _kChannel.invokeMethod<void>(
      'setParameter',
      <String, Object>{'id': id, 'value': value},
    );
  }

  /// 播放动作组。
  Future<void> startMotion(String group, int index, {int priority = 1}) {
    return _kChannel.invokeMethod<void>(
      'startMotion',
      <String, Object>{
        'group': group,
        'index': index,
        'priority': priority,
      },
    );
  }

  /// 暂停/恢复出帧（窗口最小化等不可见场景省 CPU，GL 上下文保留）。
  Future<void> setPaused(bool paused) {
    return _kChannel.invokeMethod<void>(
      'setPaused',
      <String, Object>{'paused': paused},
    );
  }

  Future<void> _disposeInternal() async {
    if (_textureId == null) return;
    try {
      await _kChannel.invokeMethod<void>('dispose');
    } on PlatformException {
      // 释放失败不阻断
    }
    _textureId = null;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_disposeInternal());
    super.dispose();
  }
}

/// 显示 [controller] 对应纹理的组件；未创建时显示占位。
class WindowsLive2DView extends StatelessWidget {
  const WindowsLive2DView({
    super.key,
    required this.controller,
    this.placeholder = const SizedBox.shrink(),
  });

  final WindowsLive2DController controller;
  final Widget placeholder;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final id = controller.textureId;
        if (id == null) return placeholder;
        return Texture(textureId: id);
      },
    );
  }
}
