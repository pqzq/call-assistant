import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Windows 原生 Live2D 渲染插件（纹理路线）。
///
/// C++ 侧在独立渲染线程离屏渲染，逐帧以 RGBA 像素缓冲推给 Flutter 合成。
///
/// **多实例**：每个 [WindowsLive2DController] 在原生侧对应一个独立实例
/// （自己的渲染线程 + GL 上下文 + 纹理）。桌面分栏和全屏演示页可能同时
/// 存在，共用单实例会互相顶掉 —— 一方 dispose 就把另一方销毁，
/// 表现为「打开演示模式后两边都空白」。
const MethodChannel _kChannel = MethodChannel('flutter_live2d_windows');

/// 一个 Live2D 渲染实例的控制器，与一个纹理 id 一一对应。
class WindowsLive2DController extends ChangeNotifier {
  /// 原生侧实例 id（create 成功后有效，后续调用用它定位自己的实例）
  int? _instanceId;
  int? _textureId;
  bool _disposed = false;

  /// 引擎侧纹理 id；create 成功后有效。
  int? get textureId => _textureId;

  /// 已释放后**任何 channel 调用都必须跳过**：
  /// C++ 侧的渲染实例已经销毁，再调过去会访问已释放的资源 → 进程崩溃。
  bool get _usable => !_disposed;

  /// 调用带实例 id 的方法（未 create 时不发）
  Future<void> _invoke(String method, Map<String, Object> extra) {
    final id = _instanceId;
    if (!_usable || id == null) return Future<void>.value();
    return _kChannel.invokeMethod<void>(method, <String, Object>{
      'id': id,
      ...extra,
    });
  }

  /// 创建渲染实例与纹理。[width]/[height] 用**物理像素**（逻辑尺寸 × dpr）。
  Future<int?> create({required double width, required double height}) async {
    if (!_usable) return null;
    if (_textureId != null) return _textureId;
    final payload = await _kChannel.invokeMethod<Map<dynamic, dynamic>>(
      'create',
      <String, double>{'width': width, 'height': height},
    );
    _instanceId = payload?['id'] as int?;
    _textureId = payload?['textureId'] as int?;
    notifyListeners();
    return _textureId;
  }

  /// 尺寸变化（物理像素），不重建纹理。
  Future<void> setSize({required double width, required double height}) {
    return _invoke('setSize', <String, Object>{
      'width': width,
      'height': height,
    });
  }

  /// 模型放大系数（1.0 = 按自动适配的结果显示）。
  ///
  /// 原生侧按「角色本体」contain 适配后角色常比 WebView 略小，
  /// 设置里的「模型大小」滑杆需要能调它。
  Future<void> setZoom(double zoom) {
    return _invoke('setZoom', <String, Object>{'zoom': zoom});
  }

  /// 设置「角色本体」在 canvas 里的归一化矩形（中心x, 中心y, 宽, 高）。
  ///
  /// 原生侧没有 `getLocalBounds()` 的等价 API：
  /// - 用 canvas 适配 → canvas 四周留白大，角色显得小
  /// - 用 drawable 顶点并集 → 外框含背景/遮罩，mao 这类模型大出好几倍，缩得更小
  /// 所以由 WebView 侧量好这个矩形传进来。
  Future<void> setFitBounds(double cx, double cy, double w, double h) {
    return _invoke('setFitBounds', <String, Object>{
      'cx': cx,
      'cy': cy,
      'w': w,
      'h': h,
    });
  }

  /// 加载模型。[dir] 为模型目录绝对路径（含结尾分隔符也可省略），
  /// [file] 为 *.model3.json 文件名。异步执行，完成后纹理自动切换为模型画面。
  Future<bool> loadModel({required String dir, required String file}) async {
    final id = _instanceId;
    if (!_usable || id == null) return false;
    final ok = await _kChannel.invokeMethod<bool>('loadModel', <String, Object>{
      'id': id,
      'dir': dir,
      'file': file,
    });
    return ok ?? false;
  }

  /// 设置模型参数（如嘴型 ParamMouthOpenY，0~1）。
  ///
  /// 注意 `id2` 是**模型参数名**：`id` 已被实例 id 占用。
  Future<void> setParameter(String id, double value) {
    return _invoke('setParameter', <String, Object>{
      'id2': id,
      'value': value,
    });
  }

  /// 播放动作组。
  Future<void> startMotion(String group, int index, {int priority = 1}) {
    return _invoke('startMotion', <String, Object>{
      'group': group,
      'index': index,
      'priority': priority,
    });
  }

  /// 暂停/恢复出帧（窗口最小化等不可见场景省 CPU，GL 上下文保留）。
  Future<void> setPaused(bool paused) {
    return _invoke('setPaused', <String, Object>{'paused': paused});
  }

  Future<void> _disposeInternal() async {
    final id = _instanceId;
    if (id == null) return;
    _instanceId = null;
    _textureId = null;
    try {
      await _kChannel.invokeMethod<void>('dispose', <String, Object>{'id': id});
    } on PlatformException {
      // 释放失败不阻断
    }
  }

  /// 释放渲染实例。
  ///
  /// ⚠️ `ChangeNotifier.dispose()` 不能改成 async，所以真正的释放放在这里。
  /// 切换渲染后端时**必须 await 它**：C++ 侧销毁完成前不能创建下一个实例，
  /// 否则两个 GL 上下文互相踩（表现为切换时报错 / 崩溃）。
  Future<void> disposeAsync() async {
    if (_disposeStarted) return _disposeFuture ?? Future<void>.value();
    _disposeStarted = true;
    _disposed = true;
    _disposeFuture = _disposeInternal();
    await _disposeFuture;
  }

  bool _disposeStarted = false;
  Future<void>? _disposeFuture;

  @override
  void dispose() {
    _disposed = true;
    unawaited(disposeAsync());
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
