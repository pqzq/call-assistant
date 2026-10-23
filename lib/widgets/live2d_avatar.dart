import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../services/live2d_service.dart';

/// Live2D 数字人：WebView 渲染，嘴型由外部 [mouth]（0~1）实时驱动。
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
  WebViewController? _controller;
  String? _error;
  bool _pageReady = false;
  Timer? _throttle;
  double _pendingMouth = -1;

  @override
  void initState() {
    super.initState();
    widget.mouth.addListener(_onMouthChanged);
    _bootstrap();
  }

  @override
  void didUpdateWidget(covariant Live2dAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换了模型就重新加载
    if (oldWidget.modelPath != widget.modelPath) {
      _bootstrap();
    }
  }

  @override
  void dispose() {
    widget.mouth.removeListener(_onMouthChanged);
    _throttle?.cancel();
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
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setOnConsoleMessage((message) => debugPrint('[Live2D] ${message.message}'))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _pageReady = true;
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

    try {
      await controller.loadRequest(Uri.parse(url));
    } catch (e) {
      if (mounted) setState(() => _error = '加载数字人失败：$e');
      return;
    }

    if (!mounted) return;
    setState(() {
      _controller = controller;
      _error = null;
      _pageReady = false;
    });
  }

  void _onMouthChanged() => _pushMouth(widget.mouth.value);

  /// 节流到 ~100ms 一次，避免频繁跨端调用
  void _pushMouth(double value, {bool force = false}) {
    _pendingMouth = value;
    if (_throttle?.isActive ?? false) return;
    if (!force && !_pageReady) return;
    _flushMouth();
    _throttle = Timer(const Duration(milliseconds: 100), _flushMouth);
  }

  DateTime _lastMouthLog = DateTime.fromMillisecondsSinceEpoch(0);

  void _flushMouth() {
    final controller = _controller;
    if (controller == null || !_pageReady) return;
    final value = _pendingMouth;
    _pendingMouth = -1;
    // 夹到 0~1，保留两位小数减少传输体积
    final clamped = value.clamp(0.0, 1.0).toStringAsFixed(2);
    unawaited(
      controller.runJavaScript('window.avatar && avatar.setMouth($clamped);').catchError((_) {}),
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
    final controller = _controller;
    if (controller == null) {
      return _placeholder('数字人初始化中…');
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: widget.height,
        width: double.infinity,
        color: const Color(0xFFEAF0FF),
        child: WebViewWidget(controller: controller),
      ),
    );
  }

  Widget _placeholder(String message, {bool isError = false}) {
    return Container(
      height: widget.height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: isError ? const Color(0xFFFDECEC) : const Color(0xFFEAF0FF),
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
        ],
      ),
    );
  }
}
