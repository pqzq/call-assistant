import 'package:flutter/widgets.dart';

import '../services/platform_bridge.dart';

/// 数字人渲染后端
enum AvatarBackend {
  /// WebView（PIXI + Cubism Web SDK）—— 全平台可用，默认
  webview('webview', 'WebView'),

  /// 原生（Cubism Native SDK + OpenGL ES）—— 目前仅 Android / iOS
  ///
  /// 依赖 `flutter_live2d` 插件。该插件 1.0.2 有两个上游 bug
  /// （CubismFramework 在没有 GL context 的线程初始化、shader 文件没打进 APK），
  /// 会导致「模型加载成功但画面永远空白」。
  /// 构建前必须执行 `dart run tool/patch_live2d_plugin.dart` 打补丁（已接入 CI）。
  native('native', '原生');

  const AvatarBackend(this.name, this.displayName);

  final String name;
  final String displayName;

  static AvatarBackend fromName(String? name) {
    for (final b in AvatarBackend.values) {
      if (b.name == name) return b;
    }
    // 没存过（首次安装）→ 跟着平台默认走。
    // 之前这里硬返回 webview，导致「默认原生」的改动对新装用户也不生效。
    return kDefaultAvatarBackend;
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

  /// 模型放大系数（1.0 = 按自动适配的结果显示）
  ///
  /// 各后端实现自己的通道：
  /// - WebView：页面内 `avatar.setZoom()` 重排（不重新加载）
  /// - Android 原生：`__zoom__` 特殊参数，C++ 乘到适配缩放上
  /// - Windows 原生：插件 channel `setZoom`
  ///
  /// 设置里的「模型大小」以前只对 WebView 生效，原生后端因为按 canvas
  /// 适配会显得偏小，所以两端都要能调。
  void setZoom(double zoom) {}

  /// 贴边紧凑模式
  ///
  /// 贴边时浮窗只剩一条窄边，但**不能重建渲染视图**（Android 平台视图
  /// 重建 / resize 都会重建 surface，肉眼可见地卡）。
  /// 这里让后端把模型在**视图内部**缩小，并贴到视图的某一侧，
  /// 上层再用裁剪把那一侧露出来。
  ///
  /// [side] 为 `right` 表示贴到视图右侧，否则贴左侧。
  /// 不支持的后端忽略即可（此时上层退化为纯裁剪）。
  void setCompact(
    bool enabled, {
    String side = 'left',
    double width = 0,
    double height = 0,
    /// 角色盒高度（缩放系数的分母：缩放系数 = 目标高度 / 角色盒高度）
    double boxHeight = 0,
  }) {}

  /// 紧凑模式下模型在视图里的位置（用于决定裁剪露出哪一块）
  ///
  /// - `center`：模型居中（原生后端：只裁剪不缩放，露中央的脸和上半身）
  /// - `right`：模型靠右（WebView 后端：模型缩到窄条尺寸后靠右）
  String get compactAlignment => 'center';

  // 说明：紧凑模式下模型在视图里的位置
  // - `center`：模型居中（原生后端：只裁剪不缩放，露中央的脸和上半身）
  // - `right`：模型靠右（WebView 后端：模型缩到窄条尺寸后靠右）

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
      // Windows 由自研 flutter_live2d_windows（外部纹理路线）支持；
      // Android/iOS 走 flutter_live2d；macOS/Linux 仍无原生实现。
      if (PlatformBridge.isWindows) return null;
      if (PlatformBridge.isDesktop) {
        return '原生渲染支持 Android / iOS / Windows，当前桌面平台请用 WebView';
      }
      return null;
  }
}

/// 默认后端
///
/// **Windows 和 Android 都默认用原生**（自研纹理插件 / 打过补丁的
/// `flutter_live2d`）：
///
/// - Windows：WebView2 会常驻 `msedgewebview2.exe`（浏览器进程 + GPU 进程 +
///   渲染进程），内存占用明显高于原生；原生走外部纹理，同进程内合成
/// - Android：WebView 要起一整个 Chromium 内核 + 页面里的 PIXI / Cubism
///   Web SDK，而原生走 SurfaceTexture，占用和启动都快一截
///
/// 其他平台（macOS / Linux）保持 WebView —— 没有原生实现。
///
/// 需要 WebView 时仍然可以在设置页手动切（选择会被记住）。
///
/// ⚠️ Android 的原生后端依赖 `flutter_live2d` 的本地补丁：
/// 构建前要跑 `dart run tool/patch_live2d_plugin.dart`，
/// 否则原生后端初始化会失败（补丁内容见 `tool/patches/`）。
AvatarBackend get kDefaultAvatarBackend =>
    (PlatformBridge.isWindows || PlatformBridge.isAndroid)
        ? AvatarBackend.native
        : AvatarBackend.webview;
