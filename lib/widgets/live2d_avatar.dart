import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart' as wv;

import '../services/live2d_service.dart';
import '../services/platform_bridge.dart';

/// Live2D 数字人：WebView 渲染，嘴型由外部 [mouth]（0~1）实时驱动。
///
/// WebView 按平台分两套实现：
/// - Android / iOS：`webview_flutter`（平台实现包自动注册）
/// - Windows：`webview_flutter_windows` 1.x 是**独立组件**（自带 WebView2），
///   不再实现 `webview_flutter` 的 WebViewPlatform，必须单独走一套 API
class Live2dAvatar extends StatefulWidget {
  const Live2dAvatar({
    super.key,
    required this.modelPath,
    required this.mouth,
    this.height = 220,
  });

  /// 相对模型路径，如 hiyori/Hiyori.model3.json
  final String modelPath;

  /// 0~1 的嘴型幅度
  final ValueListenable<double> mouth;

  final double height;

  @override
  State<Live2dAvatar> createState() => _Live2dAvatarState();
}

class _Live2dAvatarState extends State<Live2dAvatar> {
  /// Android / iOS 用的控制器
  WebViewController? _controller;

  /// Windows 用的控制器（webview_flutter_windows 1.x 独立组件）
  wv.WebviewController? _winController;

  String? _error;
  bool _pageReady = false;
  Timer? _throttle;

  /// 加载超时检测定时器
  Timer? _loadTimer;
  double _pendingMouth = -1;

  bool get _isWindows => PlatformBridge.isDesktop;

  @override
  void initState() {
    super.initState();
    widget.mouth.addListener(_onMouthChanged);
    _bootstrap();
  }

  @override
  void didUpdateWidget(covariant Live2dAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.modelPath != widget.modelPath) {
      _bootstrap();
    }
  }

  @override
  void dispose() {
    widget.mouth.removeListener(_onMouthChanged);
    _throttle?.cancel();
    _loadTimer?.cancel();
    _controller = null;
    _winController = null;
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final base = await Live2dService.instance.ensureStarted();
    if (!mounted) return;
    if (base == null) {
      setState(() => _error = '本地资源服务启动失败');
      return;
    }
    final url = '$base/index.html?model=${Uri.encodeComponent(widget.modelPath)}';
    if (_isWindows) {
      await _bootstrapWindows(url);
    } else {
      await _bootstrapMobile(url);
    }
  }
  /// Android / iOS：webview_flutter
  Future<void> _bootstrapMobile(String url) async {
    // 复用同一个 WebViewController：Android 上替换平台视图的 controller 不会刷新页面，
    // 换模型时必须对同一个 controller 再次 loadRequest
    if (_controller == null) {
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0x00000000))
        ..setOnConsoleMessage((message) => debugPrint('[Live2D] ${message.message}'))
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (_) {
              if (!mounted) return;
              setState(() {
                _pageReady = true;
                _error = null;
              });
              _pushMouth(widget.mouth.value, force: true);
            },
            onWebResourceError: (error) {
              if (!mounted || _pageReady) return;
              setState(() => _error = '页面加载失败：${error.description}');
            },
          ),
        );

      // Android 上允许无手势播放、放开调试日志
      final platform = controller.platform;
      if (platform is AndroidWebViewController) {
        try {
          await platform.setMediaPlaybackRequiresUserGesture(false);
        } catch (_) {
          // 忽略
        }
      }
      if (!mounted) return;
      setState(() => _controller = controller);
    }

    final controller = _controller;
    if (controller == null) return;
    setState(() {
      _pageReady = false;
      _error = null;
    });

    try {
      await controller.loadRequest(Uri.parse(url));
    } catch (e) {
      if (mounted) setState(() => _error = '加载数字人失败：$e');
      return;
    }
    _startLoadWatchdog();
  }

  /// Windows：webview_flutter_windows 1.x（独立 WebView2 组件）
  Future<void> _bootstrapWindows(String url) async {
    if (_winController == null) {
      final controller = wv.WebviewController();
      try {
        await controller.initialize();
      } catch (e) {
        if (mounted) {
          setState(() => _error = 'WebView2 初始化失败：$e\n'
              '请确认已安装 Microsoft Edge WebView2 Runtime');
        }
        return;
      }
      if (!mounted) {
        controller.dispose();
        return;
      }
      controller.loadingState.listen((state) {
        if (!mounted) return;
        if (state == wv.LoadingState.navigationCompleted) {
          setState(() {
            _pageReady = true;
            _error = null;
          });
          _pushMouth(widget.mouth.value, force: true);
        }
      });
      controller.onLoadError.listen((error) {
        if (!mounted || _pageReady) return;
            setState(() => _error = '页面加载失败：');
      });
      setState(() => _winController = controller);
    }

    final controller = _winController;
    if (controller == null) return;
    setState(() {
      _pageReady = false;
      _error = null;
    });

    try {
      await controller.loadUrl(url);
    } catch (e) {
      if (mounted) setState(() => _error = '加载数字人失败：$e');
      return;
    }
    _startLoadWatchdog();
  }
  /// 超时兜底：缺 WebView2 Runtime 时浏览器进程根本起不来，
  /// 不会触发任何错误回调，只会一直白屏 —— 超时后给出可操作的提示。
  void _startLoadWatchdog() {
    _loadTimer?.cancel();
    _loadTimer = Timer(const Duration(seconds: 20), () {
      if (!mounted || _pageReady) return;
      setState(() {
        _error = PlatformBridge.isDesktop
            ? '数字人加载超时：\nWindows 需要「Microsoft Edge WebView2 Runtime」，'
                '请到微软官网下载安装后重试。\n（没装也不影响播报功能）'
            : '数字人加载超时，请检查模型文件是否完整';
      });
    });
  }

  void _onMouthChanged() => _pushMouth(widget.mouth.value);

  /// 节流到 ~100ms 一次，避免频繁跨端调用
  void _pushMouth(double value, {bool force = false}) {
    _pendingMouth = value;
    if ((_throttle?.isActive ?? false)) return;
    if (!force && !_pageReady) return;
    _flushMouth();
    _throttle = Timer(const Duration(milliseconds: 100), _flushMouth);
  }

  DateTime _lastMouthLog = DateTime.fromMillisecondsSinceEpoch(0);

  void _flushMouth() {
    if (!_pageReady) return;
    final value = _pendingMouth;
    _pendingMouth = -1;
    // 夹到 0~1，保留两位小数减少传输体积
    final clamped = value.clamp(0.0, 1.0).toStringAsFixed(2);
    final script = 'window.avatar; avatar.setMouth($clamped);';

    if (_isWindows) {
      final win = _winController;
      if (win == null) return;
      unawaited(win.executeScript(script).catchError((_) {}));
      return;
    }

    final controller = _controller;
    if (controller == null) return;
    unawaited(
      controller.runJavaScript(script).catchError((_) {}),
    );

    // 说话期间每秒回读一次实际嘴型值，便于现场排查（模型没反应时看这里）
    if (value > 0.05 && DateTime.now().difference(_lastMouthLog).inMilliseconds > 800) {
      _lastMouthLog = DateTime.now();
      unawaited(
        controller
            .runJavaScriptReturningResult('window.avatar ? avatar.mouthSmooth : -1')
            .then((smooth) => debugPrint('[Live2D] mouth=$clamped smooth=$smooth'))
            .catchError((Object _) => -1),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _placeholder(_error!, isError: true);
    }
    // 背景保持透明（不能有底色，否则挡住下面的界面内容）；
    // IgnorePointer 必须包在 ClipRect 外面：ClipRect 自身也会吃掉矩形内的点击，
    // 不加它浮窗会挡住下面的号码/按钮（拨号时点不到号码）
    if (_isWindows) {
      final win = _winController;
      if (win == null) {
        return _placeholder('数字人初始化中…');
      }
      return IgnorePointer(
        child: ClipRect(
          child: SizedBox(
            height: widget.height,
            width: double.infinity,
            child: wv.Webview(win),
          ),
        ),
      );
    }
    final controller = _controller;
    if (controller == null) {
      return _placeholder('数字人初始化中…');
    }
    return IgnorePointer(
      child: ClipRect(
        child: SizedBox(
          height: widget.height,
          width: double.infinity,
          child: WebViewWidget(controller: controller),
        ),
      ),
    );
  }
  Widget _placeholder(String message, {bool isError = false}) {
    return Container(
      height: widget.height,
      width: double.infinity,
      decoration: BoxDecoration(
        // 加载/失败都用半透明，避免浮窗上出现一块实心色块
        color: isError
            ? const Color(0xFFFDECEC).withValues(alpha: 0.75)
            : Colors.white.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (!isError) const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          if (!isError) const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: isError ? const Color(0xFFD03B3B) : Colors.black45,
            ),
          ),
          // 桌面端缺 WebView2 时，直接给一个下载入口（省得用户自己找官网）
          if (isError && PlatformBridge.isDesktop) ...<Widget>[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _openWebView2Download,
              icon: const Icon(Icons.download_outlined, size: 16),
              label: const Text('下载 WebView2 Runtime', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 打开微软官方的 WebView2 Runtime 下载页
  Future<void> _openWebView2Download() async {
    const url = 'https://developer.microsoft.com/microsoft-edge/webview2/';
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      }
    } catch (_) {
      // 忽略
    }
  }
}
