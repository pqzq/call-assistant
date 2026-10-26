import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_live2d_windows/flutter_live2d_windows.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Live2D Windows Plugin Demo',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final WindowsLive2DController _controller = WindowsLive2DController();
  Timer? _mouthTimer;
  double _phase = 0;

  static const double _logicalW = 320;
  static const double _logicalH = 480;
  String _status = '初始化中…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _create());
  }

  Future<void> _create() async {
    try {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final id = await _controller.create(
        width: _logicalW * dpr,
        height: _logicalH * dpr,
      );
      setState(() => _status = 'textureId = $id，加载模型中…');
      // 开发验证：直接加载主工程 assets 里的 Hiyori
      final ok = await _controller.loadModel(
        dir: r'D:\test\flutter\call-assistant\assets\live2d\hiyori',
        file: 'Hiyori.model3.json',
      );
      setState(() => _status = 'textureId = $id，loadModel=$ok（嘴型正弦驱动中）');
      _mouthTimer = Timer.periodic(const Duration(milliseconds: 33), (timer) {
        _phase += 0.25;
        final v = math.sin(_phase) * 0.5 + 0.5;
        _controller.setParameter('ParamMouthOpenY', v);
      });
    } catch (e) {
      setState(() => _status = '创建失败: $e');
    }
  }

  @override
  void dispose() {
    _mouthTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('flutter_live2d_windows M0 验证')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(_status),
            const SizedBox(height: 16),
            Container(
              width: _logicalW,
              height: _logicalH,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey),
                color: Colors.black12,
              ),
              clipBehavior: Clip.antiAlias,
              child: WindowsLive2DView(
                controller: _controller,
                placeholder: const Center(child: CircularProgressIndicator()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
