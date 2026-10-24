import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_live2d/flutter_live2d.dart';

import '../../services/avatar_renderer.dart';
import '../../services/live2d_service.dart';

/// 原生渲染后端：Cubism Native SDK + OpenGL ES 2
///
/// 用 `flutter_live2d` 插件（自带 Cubism Core 静态库，支持 .moc3 3.0–5.3）。
/// 目前只支持 Android / iOS；Windows 上没有对应实现，会在设置里置灰。
///
/// 与 WebView 方案的差异：
/// - 不需要 HttpServer，直接读磁盘上的模型文件
/// - 嘴型走 `setParameter('ParamMouthOpenY', v)`
/// - 透明背景是插件默认行为
class NativeAvatarRenderer implements AvatarRenderer {
  NativeAvatarRenderer({this.onReady, this.onError});

  final void Function()? onReady;
  final void Function(String message)? onError;

  final Live2DViewController _controller = Live2DViewController();

  bool _loaded = false;
  bool _subscribed = false;
  double _lastMouth = 0;

  @override
  bool get isSupported => true; // 平台过滤在 backendUnsupportedReason 里做

  @override
  String? get unsupportedReason => null;

  @override
  Future<void> load(String relativePath) async {
    try {
      // 资源目录要先准备好（把 assets 释放到磁盘 + 用户导入的模型都在里面）
      final root = await Live2dService.instance.ensureWebRoot();
      if (root == null) {
        onError?.call('本地资源目录未初始化，请先开启一次数字人');
        return;
      }

      // relativePath 形如 hiyori/Hiyori.model3.json，插件要的是「目录 + 文件名」
      final normalized = relativePath.replaceAll('\\', '/');
      final slash = normalized.lastIndexOf('/');
      if (slash < 0) {
        onError?.call('模型路径不正确：$relativePath');
        return;
      }
      final modelDir = '${root.path}/${normalized.substring(0, slash)}';
      final modelFileName = normalized.substring(slash + 1);

      if (!_subscribed) {
        _subscribed = true;
        _controller.addListener(_onStateChanged);
      }

      await _controller.whenAttached;

      // 插件的两个问题：
      // 1. whenAttached 在平台视图创建时就 resolve，但 TextureView 的
      //    SurfaceTexture 是异步创建的，此刻原生侧 view->width 还是 0，
      //    nativeLoadModel 会直接返回 false。
      // 2. 如果 EGL surface 还没就绪，插件 Kotlin 侧会把 loadModel 事件
      //    **静默丢弃**（queueEvent 里判断 eglSurface != NO_SURFACE），
      //    对应 Dart Future 永远不返回 —— 所以必须自己加超时。
      var ok = false;
      for (var attempt = 0; attempt < 8 && !ok; attempt++) {
        if (attempt > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
        try {
          ok = await _controller
              .loadModel(
                modelDir: modelDir,
                modelFileName: modelFileName,
              )
              .timeout(
                const Duration(seconds: 2),
                onTimeout: () => false,
              );
        } catch (_) {
          ok = false;
        }
      }
      _loaded = ok;
      if (!ok) {
        final err = _controller.value.lastError;
        onError?.call('原生渲染加载失败：${err?.message ?? '未知原因'}');
        return;
      }
      onReady?.call();
      // 加载完后立刻同步一次当前嘴型
      setMouth(_lastMouth);
    } catch (e) {
      onError?.call('原生渲染初始化失败：$e');
    }
  }

  /// 只在「已经加载成功过、后来又出错」时才提示，避免加载中的重试被误报
  /// （一旦这里上报错误，上层会用错误框替换掉 Live2DView，插件随即 detach，
  ///  之后的 loadModel 全部会以 VIEW_NOT_ATTACHED 失败）
  void _onStateChanged() {
    final state = _controller.value;
    final err = state.lastError;
    if (err != null && _loaded) {
      _loaded = false;
      onError?.call('原生渲染错误：${err.message}');
    }
  }

  @override
  void setMouth(double value) {
    _lastMouth = value.clamp(0.0, 1.0);
    if (!_loaded) return;
    _controller.setParameter('ParamMouthOpenY', _lastMouth);
  }

  @override
  void setSpeaking(bool speaking) {
    if (!speaking) {
      _lastMouth = 0;
      if (_loaded) _controller.setParameter('ParamMouthOpenY', 0);
    }
  }

  @override
  Widget build() {
    // Live2DView 必须**始终在树里**：
    // 插件的 controller 是靠 Live2DView 挂载时才 _attach()，
    // 进而 whenAttached 才 resolve、loadModel 才能跑。
    //
    // 注意：不要用 ClipRect / IgnorePointer 包裹（平台视图在混合合成下
    // 被裁剪后可能整块不渲染），也不要因为加载状态替换掉它。
    return SizedBox.expand(
      child: Live2DView(controller: _controller),
    );
  }

  @override
  Future<void> dispose() async {
    if (_subscribed) {
      _controller.removeListener(_onStateChanged);
      _subscribed = false;
    }
    _loaded = false;
    _controller.dispose();
  }
}
