import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart' as wv;

import '../../services/avatar_renderer.dart';
import '../../services/live2d_service.dart';
import '../../services/platform_bridge.dart';

/// WebView 渲染后端：WebView 加载 PIXI + Cubism Web SDK
///
/// 从原来的 `Live2dAvatar` 整体搬过来，行为保持一致：
/// - Android / iOS：`webview_flutter`
/// - Windows：`webview_flutter_windows` 的独立组件
class WebViewAvatarRenderer implements AvatarRenderer {
  WebViewAvatarRenderer({this.onReady, this.onError});

  /// 页面就绪回调（用于上层刷新状态）
  final void Function()? onReady;

  /// 出错回调
  final void Function(String message)? onError;

  WebViewController? _controller;
  wv.WebviewController? _winController;

  bool _pageReady = false;
  Timer? _throttle;
  Timer? _loadTimer;
  double _pendingMouth = -1;
  DateTime _lastMouthLog = DateTime.fromMillisecondsSinceEpoch(0);

  /// Windows 上 WebView 的上一次宽度（用来感知 resize）
  double _lastWinWidth = 0;

  bool get _isWindows => PlatformBridge.isDesktop;

  bool get isPageReady => _pageReady;

  @override
  bool get isSupported => true;

  @override
  String? get unsupportedReason => null;

  @override
  Future<void> load(String relativePath) async {
    final base = await Live2dService.instance.ensureStarted();
    if (base == null) {
      onError?.call('本地资源服务启动失败');
      return;
    }
    final url = '$base/index.html?model=${Uri.encodeComponent(relativePath)}';
    if (_isWindows) {
      await _loadWindows(url);
    } else {
      await _loadMobile(url);
    }
  }

  // ---------------- Android / iOS ----------------

  Future<void> _loadMobile(String url) async {
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
              _pageReady = true;
              onReady?.call();
              setMouth(_pendingMouth >= 0 ? _pendingMouth : 0);
            },
            onWebResourceError: (error) {
              if (_pageReady) return;
              onError?.call('页面加载失败：${error.description}');
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
      _controller = controller;
    }

    final controller = _controller;
    if (controller == null) return;
    _pageReady = false;

    try {
      await controller.loadRequest(Uri.parse(url));
    } catch (e) {
      onError?.call('加载数字人失败：$e');
      return;
    }
    _startLoadWatchdog();
  }

  // ---------------- Windows ----------------

  Future<void> _loadWindows(String url) async {
    if (_winController == null) {
      final controller = wv.WebviewController();
      try {
        await controller.initialize();
      } catch (e) {
        onError?.call('WebView2 初始化失败：$e\n'
            '请确认已安装 Microsoft Edge WebView2 Runtime');
        return;
      }
      controller.loadingState.listen((state) {
        if (state == wv.LoadingState.navigationCompleted) {
          // 兜底：导航完成后 WebView2 控件一定已创建，此时再确保一次透明背景
          _applyTransparentBackground(controller);
          _pageReady = true;
          onReady?.call();
          setMouth(_pendingMouth >= 0 ? _pendingMouth : 0);
        }
      });
      controller.onLoadError.listen((error) {
        if (_pageReady) return;
        onError?.call('页面加载失败：');
      });
      _winController = controller;
    }

    final controller = _winController;
    if (controller == null) return;
    _pageReady = false;

    try {
      await controller.loadUrl(url);
      // 背景设为全透明：WebView2 默认是白色，不透明的话模型周围会有一圈白块，
      // 浮窗贴到屏幕左/右边缘时更会露出整块灰白条。
      //
      // 注意两点：
      // 1. 必须在原生 WebView2 控件创建之后调用（插件原生侧有 IsValid() 检查，
      //    控件没建好时会静默失败）—— 所以放在 loadUrl 之后，而不是 initialize 之后
      // 2. 只能传 alpha=0 的全透明；插件会把任何 alpha>0 的值当成不透明
      await _applyTransparentBackground(controller);
    } catch (e) {
      onError?.call('加载数字人失败：$e');
      return;
    }
    _startLoadWatchdog();
  }

  /// 把 WebView2 背景设为全透明
  Future<void> _applyTransparentBackground(wv.WebviewController controller) async {
    try {
      await controller.setBackgroundColor(const Color(0x00000000));
    } catch (_) {
      // 忽略：控件还没建好时插件会直接失败
    }
  }

  /// 超时兜底：缺 WebView2 Runtime 时浏览器进程根本起不来，
  /// 不会触发任何错误回调，只会一直白屏 —— 超时后给出可操作的提示。
  void _startLoadWatchdog() {
    _loadTimer?.cancel();
    _loadTimer = Timer(const Duration(seconds: 20), () {
      if (_pageReady) return;
      onError?.call(PlatformBridge.isDesktop
          ? '数字人加载超时：\nWindows 需要「Microsoft Edge WebView2 Runtime」，'
              '请到微软官网下载安装后重试。\n（没装也不影响播报功能）'
          : '数字人加载超时，请检查模型文件是否完整');
    });
  }

  // ---------------- 嘴型驱动 ----------------

  @override
  void setMouth(double value) {
    _pendingMouth = value;
    if ((_throttle?.isActive ?? false)) return;
    _flushMouth();
    _throttle = Timer(const Duration(milliseconds: 100), _flushMouth);
  }

  @override
  void setSpeaking(bool speaking) {
    if (!speaking) {
      _pendingMouth = 0;
      _flushMouth();
    }
  }

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

  // ---------------- Widget ----------------

  @override
  Widget build() {
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
            width: double.infinity,
            // WebView2 在尺寸变化（展开 <-> 贴边）后会把背景色重置回默认灰色，
            // 所以尺寸一变就重新设一次透明背景，否则贴边后会露出一条灰带。
            child: LayoutBuilder(
              builder: (context, constraints) {
                _syncWindowsBackground(win, constraints.maxWidth);
                return wv.Webview(win);
              },
            ),
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
          width: double.infinity,
          child: WebViewWidget(controller: controller),
        ),
      ),
    );
  }

  /// Windows：宽度变化时重设一次透明背景（WebView2 resize 会重置背景色）
  void _syncWindowsBackground(wv.WebviewController controller, double width) {
    if (width <= 0) return;
    if ((width - _lastWinWidth).abs() < 1) return;
    _lastWinWidth = width;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyTransparentBackground(controller);
    });
  }

  Widget _placeholder(String message) {
    return Container(
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

  /// WebView2 Runtime 下载页（Windows 缺运行时给出入口）
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

  /// 错误提示 Widget（含 WebView2 下载入口）
  Widget buildError(String message) {
    final needDownload = PlatformBridge.isDesktop &&
        (message.contains('WebView2') || message.contains('初始化') || message.contains('超时'));
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFFFDECEC).withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Color(0xFFD03B3B)),
          ),
          if (needDownload) ...<Widget>[
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

  @override
  Future<void> dispose() async {
    _throttle?.cancel();
    _loadTimer?.cancel();
    // 必须显式释放：Windows 的 WebView2 是**原生控件**，
    // 只把引用置空的话它会继续留在界面上，表现为一块擦不掉的灰色矩形。
    // （Android 的 WebViewController 由平台自动回收，没有 dispose）
    final win = _winController;
    _winController = null;
    if (win != null) {
      unawaited(win.dispose().catchError((_) {}));
    }
    _controller = null;
  }
}
