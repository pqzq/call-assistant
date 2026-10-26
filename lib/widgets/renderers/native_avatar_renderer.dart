import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_live2d/flutter_live2d.dart';

import '../../services/avatar_renderer.dart';
import '../../services/live2d_service.dart';
import '../../services/prompt_link.dart';

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
  NativeAvatarRenderer({this.onReady, this.onError, this.boxHeight = 0});

  final void Function()? onReady;
  final void Function(String message)? onError;

  /// 角色盒高度（说明）
  final double boxHeight;

  final Live2DViewController _controller = Live2DViewController();

  bool _loaded = false;
  bool _subscribed = false;
  double _lastMouth = 0;

  /// 上一次下发的紧凑状态（避免重复下发）
  bool? _lastCompact;

  /// 监听 PromptLink 的贴边紧凑状态
  ///
  /// 不能只靠 `Live2dAvatar` 的回调转发 —— 浮窗裁剪会改变 widget 树结构，
  /// 那边的回调时序不可靠，结果就是贴边时缩放指令发不出去。
  /// renderer 自己监听最稳。
  /// 上一次下发的本体边界（避免重复）
  List<double>? _lastFitBounds;

  /// 把「角色本体在 canvas 里的归一化矩形」下发给原生侧
  ///
  /// 原生侧没有 getLocalBounds() 的等价 API，只能靠 WebView 侧量到的
  /// 这个矩形按**角色本体**（而不是含大量留白的 canvas）对齐，
  /// 否则原生和 WebView 的效果对不上（模型又小又偏）。
  void _pushFitBounds() {
    final b = PromptLink.instance.avatarModelBounds;
    if (b.length != 4) {
      // 当前模型还没量到本体边界（或刚换了模型）：
      // **必须主动清掉 C++ 侧缓存的旧值**，否则它会继续拿上一个模型的
      // 归一化矩形算缩放 —— 不同模型 canvas 尺寸差很多，实测 mao 会小几倍。
      // `__fit_h__ = 0` 会让 C++ 把 fitBoundsValid 置 false，退回按 canvas 适配。
      if (_lastFitBounds != null) {
        _lastFitBounds = null;
        if (_loaded) {
          _controller.setParameter('__fit_h__', 0);
        }
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
    if (!_loaded) return;
    _controller.setParameter('__fit_cx__', b[0]);
    _controller.setParameter('__fit_cy__', b[1]);
    _controller.setParameter('__fit_w__', b[2]);
    _controller.setParameter('__fit_h__', b[3]);
  }

  void _onLinkChanged() {
    // 同步本体边界（让原生按角色本体适配，和 WebView 一致）
    _pushFitBounds();
    final link = PromptLink.instance;
    if (link.avatarCompact == _lastCompact) return;
    _lastCompact = link.avatarCompact;
    setCompact(
      link.avatarCompact,
      side: link.avatarCompactSide,
      width: link.avatarCompactWidth,
      height: link.avatarCompactHeight,
      boxHeight: boxHeight,
    );
  }

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
        // 自己监听贴边紧凑状态（不依赖上层 widget 的回调时序）
        PromptLink.instance.addListener(_onLinkChanged);
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
      // 模型加载好了，把本体边界补发一次（边界比模型先到）
      _pushFitBounds();
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
    _controller.setParameter('ParamMouthOpenY', _lastMouth);
  }

  @override
  void setSpeaking(bool speaking) {
    if (!speaking) {
      _lastMouth = 0;
      if (_loaded) _controller.setParameter('ParamMouthOpenY', 0);
    }
  }

  /// 贴边紧凑模式：把模型在视图内缩小并贴到右上角（和 WebView 侧同思路）
  ///
  /// TextureView / 投影空间都不能任意变换，只能在渲染矩阵里缩：
  /// 下发窄条相对展开视图的 NDC 占比，C++ 侧 ApplyCompactFit 按
  /// 「角色本体边界」（WebView 量到的 __fit_*__）把模型缩到窄条范围
  /// 并贴到视图右上角；Flutter 侧裁剪露出的正是右上角 → 能看到完整的
  /// 缩小版模型。参数非法 / 未启用时 C++ 退回普通适配，模型不会消失。
  @override
  void setCompact(
    bool enabled, {
    String side = 'left',
    double width = 0,
    double height = 0,
    double boxHeight = 0,
  }) {
    if (!_loaded) return;
    // 相对占比无效（上层没传尺寸）时不下发，保持普通适配
    //
    // 窄条贴视图右上角裁剪：一个占视图**宽度分数 f** 且贴右边缘的区,
    // 在 NDC（[-1,1]）里是 [1-2f, 1]，其**半宽**恰好 = f。所以
    // halfW / hRatio 都直接传「占视图的分数」，C++ 侧当作 NDC 半宽高用。
    final hRatio = (enabled && boxHeight > 0 && height > 0)
        ? (height / boxHeight).clamp(0.0, 1.0).toDouble()
        : 0.0;
    final viewWidth = boxHeight > 0 ? _viewWidthFor(boxHeight) : 0.0;
    final halfW = (enabled && viewWidth > 0 && width > 0)
        ? (width / viewWidth).clamp(0.0, 1.0).toDouble()
        : 0.0;
    // 窄条占比接近 1 = 其实没缩小，不必进紧凑排版（C++ 侧也有同样兑底）
    final on = enabled && hRatio > 0.01 && hRatio < 0.99 && halfW > 0.01 && halfW < 0.99;
    _controller.setParameter('__compact_enable__', on ? 1.0 : 0.0);
    if (on) {
      _controller.setParameter('__compact_half_w__', halfW);
      _controller.setParameter('__compact_h_ratio__', hRatio);
    }
  }

  /// 平台视图（展开态）的逻辑宽度：角色盒宽度
  ///
  /// 与 [FloatingAvatarHost] 的公式一致（那里不能直接引用，否则构成
  /// 循环依赖），常量同步维护：高 × clamp(0.28~0.90)、兑底宽 232。
  double _viewWidthFor(double boxH) {
    const double minAspect = 0.28;
    const double maxAspect = 0.90;
    const double defaultAspect = 0.58;
    const double minBoxWidth = 232.0;
    final raw = PromptLink.instance.avatarModelAspect;
    final effAspect = raw > 0 ? raw.clamp(minAspect, maxAspect) : defaultAspect;
    final byAspect = boxH * effAspect;
    return byAspect < minBoxWidth ? minBoxWidth : byAspect;
  }

  /// 紧凑后模型贴视图右上角（ApplyCompactFit 就是这么排的），
  /// 和 WebView 侧一致 → 上层裁剪露出右上角即可
  @override
  String get compactAlignment => 'topRight';

  /// 角色盒高度（用于算紧凑模式的缩放系数）
  /// 角色盒高度（说明）
  // ignore: unused_element
  double get _boxHeight => boxHeight;


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
      PromptLink.instance.removeListener(_onLinkChanged);
      _subscribed = false;
    }
    _loaded = false;
    _controller.dispose();
  }
}
