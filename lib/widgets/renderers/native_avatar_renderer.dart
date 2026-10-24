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
      final ok = await _controller.loadModel(
        modelDir: modelDir,
        modelFileName: modelFileName,
      );
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

  void _onStateChanged() {
    final state = _controller.value;
    final err = state.lastError;
    if (err != null && !_loaded) {
      onError?.call('原生渲染错误：${err.message}');
      _loaded = false;
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
    return IgnorePointer(
      child: ClipRect(
        child: SizedBox(
          width: double.infinity,
          child: ValueListenableBuilder<Live2DViewState>(
            valueListenable: _controller,
            builder: (context, state, _) {
              if (state.isLoadingModel) {
                return const Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              }
              if (!state.isLoaded) {
                return const SizedBox.shrink();
              }
              return const Live2DView();
            },
          ),
        ),
      ),
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
