import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_live2d_windows/flutter_live2d_windows.dart';

import '../../services/avatar_renderer.dart';
import '../../services/live2d_service.dart';
import '../../services/prompt_link.dart';

/// Windows 原生渲染后端：自研插件 flutter_live2d_windows（外部纹理路线）。
///
/// 与 Android 的 NativeAvatarRenderer 差异：
/// - 不是平台视图：C++ 在独立 GL 线程离屏渲染，Dart 用 Texture 显示，
///   天然被 Flutter 合成/裁剪，无 resize 闪断问题
/// - 桌面为分栏布局、无贴边收起，setCompact 为空实现
/// - 渲染尺寸跟随布局：LayoutBuilder 拿逻辑尺寸 × dpr → create / setSize
class WindowsNativeAvatarRenderer
    with WidgetsBindingObserver
    implements AvatarRenderer {
  WindowsNativeAvatarRenderer({this.onReady, this.onError}) {
    WidgetsBinding.instance.addObserver(this);
    // 监听 PromptLink：本体边界 / 模型变化时同步给原生侧
    PromptLink.instance.addListener(_onLinkChanged);
  }

  final void Function()? onReady;
  final void Function(String message)? onError;

  final WindowsLive2DController _controller = WindowsLive2DController();

  bool _created = false;
  bool _loaded = false;
  double _lastMouth = 0;
  Size _lastPx = Size.zero;
  String? _pendingModel;

  /// 是否正在加载模型（防止两条路径并发调 loadModel）
  bool _loading = false;

  /// 是否已释放 —— 释放后所有插件调用都要跳过，否则 C++ 侧会访问已销毁的实例
  bool _disposed = false;

  static bool _sizeDiffers(Size a, Size b) =>
      (a.width - b.width).abs() >= 1 || (a.height - b.height).abs() >= 1;

  @override
  bool get isSupported => true;

  @override
  String? get unsupportedReason => null;

  @override
  Future<void> load(String relativePath) async {
    _pendingModel = relativePath;
    // 未 create（还没有尺寸）时先记下，等 build 首帧拿到尺寸再加载
    if (_created) await _loadPending();
  }


  /// 模型放大系数（设置里的「模型大小」）
  double _zoom = 1.0;

  /// 上一次下发的本体边界（避免重复下发）
  List<double>? _lastFitBounds;

  @override
  void setZoom(double zoom) {
    final v = zoom.clamp(0.5, 2.5).toDouble();
    if ((v - _zoom).abs() < 0.001) return;
    _zoom = v;
    if (_loaded && !_disposed) unawaited(_controller.setZoom(_zoom));
  }

  /// 把「角色本体在 canvas 里的归一化矩形」下发给原生
  ///
  /// Windows 侧适配如果只用 canvas 会偏小、只用 drawable 顶点外框会更小
  /// （外框含背景/遮罩），所以要用 WebView 量到的本体边界。
  void _pushFitBounds() {
    if (_disposed) return;
    final b = PromptLink.instance.avatarModelBounds;
    if (b.length != 4) {
      if (_lastFitBounds != null) {
        _lastFitBounds = null;
        // 0 宽高 = 清空，原生侧退回按 canvas 适配
        if (_loaded) unawaited(_controller.setFitBounds(0, 0, 0, 0));
      }
      return;
    }
    final last = _lastFitBounds;
    if (last != null && last.length == 4) {
      var same = true;
      for (var i = 0; i < 4; i++) {
        if ((last[i] - b[i]).abs() > 0.002) {
          same = false;
          break;
        }
      }
      if (same) return;
    }
    _lastFitBounds = List<double>.from(b);
    if (_loaded) {
      unawaited(_controller.setFitBounds(b[0], b[1], b[2], b[3]));
    }
  }

  void _onLinkChanged() => _pushFitBounds();

  Future<void> _loadPending() async {
    final rel = _pendingModel;
    if (rel == null || !_created || _disposed) return;
    // ⚠️ 防止并发加载：`load()` 与「create 完成后的回调」是两条独立路径，
    // 都可能触发这里。同时调 loadModel 会让 C++ 侧并发加载模型 → 崩溃。
    if (_loading) return;
    _loading = true;
    try {
      await _loadPendingInner(rel);
    } finally {
      _loading = false;
    }
  }

  Future<void> _loadPendingInner(String rel) async {

    final root = await Live2dService.instance.ensureWebRoot();
    if (root == null) {
      onError?.call('本地资源目录未初始化，请先开启一次数字人');
      return;
    }
    final normalized = rel.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    if (slash < 0) {
      onError?.call('模型路径不正确：$rel');
      return;
    }
    // 内置模型可能不在 userdata 里（桌面端不复制内置资源，直接读 app 自带目录），
    // 所以目录要按同一套规则解析：先 userdata，再 app 自带资源。
    final dir = Live2dService.resolveModelDir(root.path, normalized);
    final file = normalized.substring(slash + 1);

    final ok = await _controller.loadModel(dir: dir, file: file);
    if (!ok) {
      onError?.call('模型加载失败：$file');
      return;
    }
    _loaded = true;
    // 模型就绪后补发缩放与本体边界（两者都要在加载之后才生效）
    if (!_disposed) {
      unawaited(_controller.setZoom(_zoom));
      _pushFitBounds();
    }
    _pendingModel = null;
    setMouth(_lastMouth);
    onReady?.call();
  }

  Future<void> _syncSize(Size px) async {
    if (_disposed) return;
    if (px.width < 1 || px.height < 1) return;
    if (!_sizeDiffers(px, _lastPx)) return;
    _lastPx = px;
    if (!_created) {
      try {
        // create 返回 null 有两种情况：controller 已释放，或原生的 create
        // 没有返回有效纹理 id。以前这里直接置 _created = true，于是
        // WindowsLive2DView 一直显示 placeholder（纯白），没有任何提示 ——
        // 表现为「数字人区域空白、也没有错误框」，很难排查。
        final textureId =
            await _controller.create(width: px.width, height: px.height);
        if (textureId == null) {
          if (!_disposed) {
            onError?.call('纹理创建失败：原生 create 没有返回有效纹理 id');
          }
          return;
        }
        _created = true;
        await _loadPending();
      } catch (e) {
        onError?.call('Windows 原生渲染初始化失败：$e');
      }
    } else {
      await _controller.setSize(width: px.width, height: px.height);
    }
  }

  @override
  void setMouth(double value) {
    _lastMouth = value.clamp(0.0, 1.0);
    if (_loaded && !_disposed) {
      unawaited(_controller.setParameter('ParamMouthOpenY', _lastMouth));
    }
  }

  @override
  void setSpeaking(bool speaking) {
    if (!speaking) {
      _lastMouth = 0;
      if (_loaded && !_disposed) {
        unawaited(_controller.setParameter('ParamMouthOpenY', 0));
      }
    }
  }

  @override
  void setCompact(
    bool enabled, {
    String side = 'left',
    double width = 0,
    double height = 0,
    double boxHeight = 0,
  }) {}

  @override
  String get compactAlignment => 'center';

  @override
  Widget build() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final px = Size(
          constraints.maxWidth.isFinite ? constraints.maxWidth * dpr : 0,
          constraints.maxHeight.isFinite ? constraints.maxHeight * dpr : 0,
        );
        if (px.width >= 1 && px.height >= 1 && _sizeDiffers(px, _lastPx)) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _syncSize(px));
        }
        return WindowsLive2DView(
          controller: _controller,
          placeholder: const SizedBox.shrink(),
        );
      },
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    PromptLink.instance.removeListener(_onLinkChanged);
    // 必须**等到** C++ 侧真正销毁：切换后端时会紧接着创建下一个实例，
    // 旧的还没销毁就 create 新的，两个 GL 上下文会互相踩（表现为切换时崩溃）。
    await _controller.disposeAsync().catchError((_) {});
  }

  /// 窗口最小化/失焦隐藏时暂停出帧（省 CPU，恢复时自动继续）
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_created) return;
    final paused = state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive;
    unawaited(_controller.setPaused(paused));
  }
}
