import 'package:flutter/widgets.dart';

import '../services/platform_bridge.dart';

/// 数字人渲染后端
enum AvatarBackend {
  /// WebView（PIXI + Cubism Web SDK）—— 全平台可用，默认
  webview('webview', 'WebView'),

  /// 原生（Cubism Native SDK + OpenGL ES）—— 目前仅 Android / iOS
  native('native', '原生渲染');

  const AvatarBackend(this.name, this.displayName);

  final String name;
  final String displayName;

  static AvatarBackend fromName(String? name) {
    for (final b in AvatarBackend.values) {
      if (b.name == name) return b;
    }
    return webview;
  }
}

/// 数字人渲染后端抽象
///
/// 两种实现：
/// - `WebViewAvatarRenderer`：WebView 加载 PIXI + Cubism Web SDK（全平台）
/// - `NativeAvatarRenderer`：Cubism Native SDK + OpenGL ES（Android / iOS）
///
/// 上层（Live2dAvatar）只依赖这个接口，按用户选择的后端创建具体实现。
abstract class AvatarRenderer {
  /// 当前平台是否支持该后端
  bool get isSupported;

  /// 不支持的原因（展示给用户）
  String? get unsupportedReason;

  /// 加载模型
  ///
  /// [relativePath] 是相对资源根目录的路径，如 `hiyori/Hiyori.model3.json`
  Future<void> load(String relativePath);

  /// 设置嘴型幅度（0~1）
  void setMouth(double value);

  /// 说话开关（关闭时复位嘴型）
  void setSpeaking(bool speaking);

  /// 构建渲染 Widget（尺寸由外部约束）
  Widget build();

  /// 释放资源
  Future<void> dispose();
}

/// 按平台判断某个后端是否可用，返回不可用原因（可用时返回 null）
String? backendUnsupportedReason(AvatarBackend backend) {
  switch (backend) {
    case AvatarBackend.webview:
      return null; // 全平台可用
    case AvatarBackend.native:
      if (PlatformBridge.isDesktop) {
        return '原生渲染暂只支持 Android / iOS，Windows 请用 WebView';
      }
      return null;
  }
}

/// 默认后端：保持 WebView（零风险，行为与之前一致）
const AvatarBackend kDefaultAvatarBackend = AvatarBackend.webview;
