import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/avatar_renderer.dart';
import '../services/prompt_link.dart';
import 'renderers/native_avatar_renderer.dart';
import 'renderers/webview_avatar_renderer.dart';

/// Live2D 数字人：按用户选择的渲染后端展示，嘴型由外部 [mouth]（0~1）实时驱动。
///
/// 渲染后端可切换（设置项 `avatar_backend`）：
/// - **WebView**：WebView 加载 PIXI + Cubism Web SDK，全平台可用（默认）
/// - **原生**：Cubism Native SDK + OpenGL ES，目前仅 Android / iOS
///
/// 两种后端都实现 [AvatarRenderer]，本类只做调度：创建 / 切换 / 转发嘴型。
class Live2dAvatar extends StatefulWidget {
  const Live2dAvatar({
    super.key,
    required this.modelPath,
    required this.mouth,
    this.height = 220,
    this.backend,
    this.compact = false,
    this.compactSide = 'left',
    this.compactWidth = 0,
    this.compactHeight = 0,
  });

  /// 相对模型路径，如 hiyori/Hiyori.model3.json
  final String modelPath;

  /// 0~1 的嘴型幅度
  final ValueListenable<double> mouth;

  final double height;

  /// 渲染后端（不传则用全局设置）
  final AvatarBackend? backend;

  /// 贴边紧凑模式：模型在渲染视图内部缩小并贴到 [compactSide] 一侧
  final bool compact;

  /// 紧凑模式下模型贴向哪一侧（`right` = 靠右，否则靠左）
  final String compactSide;

  /// 紧凑模式下的目标尺寸（逻辑像素）
  final double compactWidth;
  final double compactHeight;

  @override
  State<Live2dAvatar> createState() => _Live2dAvatarState();
}

class _Live2dAvatarState extends State<Live2dAvatar> {
  AvatarRenderer? _renderer;
  String? _error;

  /// 当前 renderer 用的后端（用于判断是否需要重建）
  AvatarBackend? _currentBackend;

  /// 当前已下发到页面的放大系数（用于判断是否需要重新推送）
  double _currentZoom = 1.0;

  @override
  void initState() {
    super.initState();
    widget.mouth.addListener(_onMouthChanged);
    // 后端设置是异步读的（SharedPreferences），init 完成前可能还是默认值，
    // 这里监听 PromptLink，等它 notify 后再按真实后端重建一次
    PromptLink.instance.addListener(_onLinkChanged);
    _initRenderer();
  }

  @override
  void didUpdateWidget(covariant Live2dAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.modelPath != widget.modelPath) {
      _loadModel();
      return;
    }
    // 贴边紧凑模式变化：通知后端把模型在视图内缩小（不重建视图）
    if (oldWidget.compact != widget.compact ||
        oldWidget.compactSide != widget.compactSide ||
        oldWidget.compactWidth != widget.compactWidth ||
        oldWidget.compactHeight != widget.compactHeight) {
      _renderer?.setCompact(
        widget.compact,
        side: widget.compactSide,
        width: widget.compactWidth,
        height: widget.compactHeight,
      );
    }
  }

  /// PromptLink 刷新（含后端切换、init 完成）时，按最新后端重建 renderer
  void _onLinkChanged() {
    if (!mounted) return;
    final target = widget.backend ?? PromptLink.instance.avatarBackend;
    if (target != _currentBackend) {
      _initRenderer();
      return;
    }
    // 「模型大小」滑杆变了就实时推给页面（重排即可，不用重新加载）
    final zoom = PromptLink.instance.avatarModelZoom;
    if ((zoom - _currentZoom).abs() > 0.001) {
      _currentZoom = zoom;
      final r = _renderer;
      if (r is WebViewAvatarRenderer) {
        r.setZoom(zoom);
      }
    }
  }

  @override
  void dispose() {
    PromptLink.instance.removeListener(_onLinkChanged);
    widget.mouth.removeListener(_onMouthChanged);
    final renderer = _renderer;
    _renderer = null;
    if (renderer != null) {
      unawaited(renderer.dispose().catchError((_) {}));
    }
    super.dispose();
  }

  /// 创建渲染后端（切换后端时会重建）
  Future<void> _initRenderer() async {
    final backend = widget.backend ?? PromptLink.instance.avatarBackend;

    // 平台不支持时给明确提示，并回退到 WebView
    var effective = backend;
    final reason = backendUnsupportedReason(backend);
    if (reason != null) {
      _error = reason;
      effective = AvatarBackend.webview;
    } else {
      _error = null;
    }

    final old = _renderer;
    _renderer = null;
    if (old != null) {
      await old.dispose();
    }

    final renderer = effective == AvatarBackend.native
        ? NativeAvatarRenderer(
            onReady: _onRendererReady,
            onError: _onRendererError,
          )
        : WebViewAvatarRenderer(
            onReady: _onRendererReady,
            onError: _onRendererError,
          );

    if (!mounted) {
      await renderer.dispose();
      return;
    }
    _currentBackend = effective;
    setState(() => _renderer = renderer);
    await _loadModel();
  }

  Future<void> _loadModel() async {
    final renderer = _renderer;
    if (renderer == null) return;
    setState(() => _error = null);
    await renderer.load(widget.modelPath);
  }

  void _onRendererReady() {
    if (!mounted) return;
    setState(() => _error = null);
    // 页面就绪后立刻同步当前嘴型
    final renderer = _renderer;
    renderer?.setMouth(widget.mouth.value);
  }

  void _onRendererError(String message) {
    if (!mounted) return;
    setState(() => _error = message);
  }

  void _onMouthChanged() {
    _renderer?.setMouth(widget.mouth.value);
  }

  @override
  Widget build(BuildContext context) {
    final renderer = _renderer;
    if (renderer == null) {
      return _placeholder('数字人初始化中…');
    }
    if (_error != null) {
      // WebView 后端的错误提示带 WebView2 下载入口
      if (renderer is WebViewAvatarRenderer) {
        return renderer.buildError(_error!);
      }
      return _errorBox(_error!);
    }
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: renderer.build(),
    );
  }

  Widget _placeholder(String message) {
    return Container(
      height: widget.height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 10),
          Text(message, style: const TextStyle(fontSize: 12, color: Colors.black45)),
        ],
      ),
    );
  }

  Widget _errorBox(String message) {
    return Container(
      height: widget.height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFFFDECEC).withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, color: Color(0xFFD03B3B)),
      ),
    );
  }
}
