import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../widgets/page_title.dart';

import '../services/prompt_link.dart';
import '../widgets/live2d_avatar.dart';
import '../widgets/app_toast.dart';
import '../widgets/desktop_body.dart';

/// 演示模式：全屏数字人 + 字幕，播报开场白。
/// 适合给客户/领导演示、录屏出素材。
class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  final PromptLink _link = PromptLink.instance;

  Timer? _ticker;
  int _elapsedMs = 0;
  int _totalMs = 0;
  bool _playing = false;

  List<String> get _steps => _link.scriptSteps;

  int get _currentStep {
    if (_steps.isEmpty) return 0;
    if (_totalMs <= 0) return 0;
    final ratio = (_elapsedMs / _totalMs).clamp(0.0, 0.999);
    return (ratio * _steps.length).floor().clamp(0, _steps.length - 1);
  }

  double get _progress => _totalMs <= 0 ? 0 : (_elapsedMs / _totalMs).clamp(0.0, 1.0);

  @override
  void initState() {
    super.initState();
    _link.addListener(_onLinkChanged);
    // 演示页是全屏场景，隐藏浮动数字人（否则会出现两个角色并挡住按钮）
    _link.setSuppressAvatar(true);
    // 演示页打开时确保数字人可用（否则 Live2dAvatar 不会渲染）
    if (!_link.avatarEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _link.setAvatarEnabled(true));
    }
  }

  @override
  void dispose() {
    _link.removeListener(_onLinkChanged);
    _link.setSuppressAvatar(false);
    _ticker?.cancel();
    super.dispose();
  }

  void _onLinkChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _startDemo() async {
    final steps = _steps;
    if (steps.isEmpty) {
      _toast('开场白是空的，先去联动页填一段话术');
      return;
    }
    _ticker?.cancel();
    setState(() {
      _playing = true;
      _elapsedMs = 0;
      _totalMs = _link.estimatedSpeakDuration.inMilliseconds;
    });
    // 真正发声（优先播已合成的 wav，其次系统 TTS）
    await _link.speak(_link.script);
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _elapsedMs += 100);
      if (_elapsedMs >= _totalMs) {
        timer.cancel();
        setState(() => _playing = false);
      }
    });
  }

  Future<void> _stopDemo() async {
    _ticker?.cancel();
    await _link.stopSpeaking();
    if (mounted) {
      setState(() {
        _playing = false;
        _elapsedMs = 0;
      });
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    AppToast.show(context, message);
  }

  Future<void> _pickModel() async {
    final models = await _link.availableAvatarModels();
    if (!mounted) return;
    if (models.isEmpty) {
      _toast('没有可用模型');
      return;
    }
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('选择数字人模型', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            for (final model in models)
              ListTile(
                title: Text(
                  model.split('/').last.replaceAll('.model3.json', ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  model,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
                trailing: model == _link.avatarModel ? const Icon(Icons.check, size: 18) : null,
                onTap: () => Navigator.of(sheetContext).pop(model),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) await _link.setAvatarModel(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final steps = _steps;
    final current = steps.isEmpty ? null : steps[_currentStep];
    return Scaffold(
      // 与「双机联动播报」页保持同一背景色
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('数字人演示', style: kPageTitleStyle),
        actions: <Widget>[
          IconButton(
            tooltip: '切换模型',
            icon: const Icon(Icons.face_retouching_natural),
            onPressed: _pickModel,
          ),
        ],
      ),
      body: DesktopBody(child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 话术框至少 4 行（每行约 24px + 内边距），剩下的高度给数字人
            const textBoxHeight = 168.0;
            final avatarHeight =
                (constraints.maxHeight - textBoxHeight - 110).clamp(320.0, 900.0);
            return Column(
              children: <Widget>[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: SizedBox(
                    height: avatarHeight,
                    width: double.infinity,
                    child: Live2dAvatar(
                      modelPath: _link.avatarModel,
                      mouth: _link.mouth,
                      height: avatarHeight,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // 字幕（固定高度，至少显示 4 行）
                Container(
                  height: textBoxHeight,
                  width: double.infinity,
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.94),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE1E7F2)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF2F6BFF).withValues(alpha: 0.85),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                steps.isEmpty ? '无话术' : '第 ${_currentStep + 1}/${steps.length} 句',
                                style: const TextStyle(fontSize: 11, color: Colors.white),
                              ),
                            ),
                            const Spacer(),
                            Text(
                              _link.activeLead == null ? '示例播报' : _link.activeLead!.name,
                              style: const TextStyle(fontSize: 12, color: Colors.black54),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: SingleChildScrollView(
                            child: Text(
                              current ?? '（还没有开场白，去联动页写一段）',
                              style: const TextStyle(
                                fontSize: 17,
                                height: 1.6,
                                color: Colors.black87,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: _progress,
                            minHeight: 3,
                            backgroundColor: const Color(0xFFE8EDF6),
                            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF4D8BFF)),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _playing ? _stopDemo : _startDemo,
                          icon: Icon(_playing ? Icons.stop : Icons.play_arrow, size: 20),
                          label: Text(_playing ? '停止' : '开始演示'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(50),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(96, 50),
                        ),
                        child: const Text('返回'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
            );
          },
        ),
      ),
      ),   // DesktopBody
    );
  }
}
