import 'package:flutter/material.dart';

import '../services/call_state_watcher.dart';
import '../services/prompt_link.dart';
import 'demo_page.dart';

/// 双机联动配置：A 手机检测接通，B 手机朗读开场白
class PromptPage extends StatefulWidget {
  const PromptPage({super.key});

  @override
  State<PromptPage> createState() => _PromptPageState();
}

class _PromptPageState extends State<PromptPage> {
  final PromptLink _link = PromptLink.instance;
  late final TextEditingController _scriptController;
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _scriptController = TextEditingController(text: _link.script);
    _nameController = TextEditingController(text: _link.deviceName);
    _link.addListener(_onChanged);
    _link.init().then((_) {
      if (!mounted) return;
      _scriptController.text = _link.script;
      _nameController.text = _link.deviceName;
      _link.refreshAccessibility();
    });
  }

  @override
  void dispose() {
    _link.removeListener(_onChanged);
    _scriptController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 从 haru/Haru.model3.json 里取出「Haru」作展示名
  String _modelLabel(String path) {
    final file = path.split('/').last;
    final name = file.replaceAll('.model3.json', '');
    if (name.isNotEmpty) return name;
    final dir = path.split('/');
    return dir.length > 1 ? dir[dir.length - 2] : path;
  }

  Future<void> _showModelPicker(List<String> models) async {
    if (models.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可用模型'), behavior: SnackBarBehavior.floating),
      );
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
                title: Text(_modelLabel(model), maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  model,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.black38),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('双机联动播报'),
        actions: <Widget>[
          PopupMenuButton<String>(
            tooltip: '数字人模型',
            icon: const Icon(Icons.face_retouching_natural),
            onSelected: (value) async {
              if (value == 'import') {
                final ok = await _link.importAvatarModel();
                if (!mounted) return;
                ScaffoldMessenger.of(this.context).showSnackBar(
                  SnackBar(
                    content: Text(ok ? '数字人模型已导入' : '导入失败，详见日志'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              } else if (value == 'models') {
                final models = await _link.availableAvatarModels();
                if (!mounted) return;
                _showModelPicker(models);
              } else if (value == 'demo') {
                Navigator.of(this.context).push(
                  MaterialPageRoute<void>(builder: (_) => const DemoPage()),
                );
              }
            },
            itemBuilder: (context) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'import', child: Text('导入模型包（zip）')),
              PopupMenuItem<String>(value: 'models', child: Text('切换已有模型')),
              PopupMenuItem<String>(value: 'demo', child: Text('演示模式（全屏）')),
            ],
          ),
          IconButton(
            tooltip: '刷新状态',
            icon: const Icon(Icons.refresh),
            onPressed: () => _link.refreshAccessibility(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: <Widget>[
          _buildStatusCard(),
          const SizedBox(height: 12),
          _buildRoleCard(),
          const SizedBox(height: 12),
          _buildAvatarCard(),
          const SizedBox(height: 12),
          _buildScriptCard(),
          const SizedBox(height: 12),
          _buildSynthCard(),
          const SizedBox(height: 12),
          _buildAudioCard(),
          const SizedBox(height: 12),
          _buildLogCard(),
          const SizedBox(height: 16),
          _buildTipCard(),
        ],
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }

  Widget _buildStatusCard() {
    final enabled = _link.accessibilityEnabled;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                enabled ? Icons.check_circle : Icons.warning_amber_rounded,
                size: 18,
                color: enabled ? const Color(0xFF17A05A) : const Color(0xFFE08A00),
              ),
              const SizedBox(width: 8),
              const Text('通话检测服务', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(
                enabled ? '已开启' : '未开启',
                style: TextStyle(
                  fontSize: 12,
                  color: enabled ? const Color(0xFF17A05A) : const Color(0xFFE08A00),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '需要「无障碍」权限来读取通话界面上的计时器，从而判断对方是否已接通。本应用不会读取或上传通话内容。',
            style: TextStyle(fontSize: 12, height: 1.5, color: Colors.black45),
          ),
          if (!enabled) ...<Widget>[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () async {
                await CallStateWatcher.openSettings();
              },
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('打开系统无障碍设置'),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Icon(
                _link.listening ? Icons.wifi : Icons.wifi_off,
                size: 16,
                color: _link.listening ? const Color(0xFF2F6BFF) : Colors.black38,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _link.listening
                      ? _link.hasPeer
                          ? '局域网已连接：${_link.peers.map((p) => p.displayName).join('、')}'
                          : '局域网监听中，等待另一台手机…'
                      : '局域网未启动',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
            ],
          ),
          if (_link.lastError != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(_link.lastError!, style: const TextStyle(fontSize: 12, color: Color(0xFFD03B3B))),
          ],
        ],
      ),
    );
  }

  Widget _buildRoleCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Icon(Icons.devices_other, size: 18, color: Color(0xFF2F6BFF)),
              SizedBox(width: 8),
              Text('本机角色', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('拨号端：接通后自动通知播放端', style: TextStyle(fontSize: 14)),
            subtitle: const Text('本机拨打电话，检测到对方接通后广播播报指令', style: TextStyle(fontSize: 11)),
            value: _link.autoTrigger,
            onChanged: (v) => _link.setAutoTrigger(v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('播放端：收到指令后朗读开场白', style: TextStyle(fontSize: 14)),
            subtitle: const Text('放在拨号手机旁边，用它来朗读（建议固定支架、对准麦克风）', style: TextStyle(fontSize: 11)),
            value: _link.asPlayer,
            onChanged: (v) => _link.setAsPlayer(v),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: '设备名（另一台手机看到的名字）',
              isDense: true,
            ),
            onSubmitted: (v) => _link.setDeviceName(v),
            onTapOutside: (_) => _link.setDeviceName(_nameController.text),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _link.triggerManually(),
                  icon: const Icon(Icons.campaign_outlined, size: 18),
                  label: const Text('立即播报'),
                ),
              ),
            ],
          ),
          if (_link.armed) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              '等待接通中：${_link.armedLabel} ${_link.armedPhone}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF2F6BFF)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSynthCard() {
    final ready = _link.ttsModelReady;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.graphic_eq, size: 18, color: Color(0xFF2F6BFF)),
              const SizedBox(width: 8),
              const Text('端侧语音合成', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: ready ? const Color(0xFFE7F7EE) : const Color(0xFFFDECEC),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  ready ? '模型就绪' : '未安装模型',
                  style: TextStyle(
                    fontSize: 11,
                    color: ready ? const Color(0xFF17A05A) : const Color(0xFFD03B3B),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '在本机离线把上面的开场白文本合成成 wav（sherpa-onnx + 中文 VITS，int8 模型约 13MB）。合成只在点按钮时跑一次，之后接通播的就是这个 wav，不需要系统 TTS。',
            style: TextStyle(fontSize: 12, height: 1.5, color: Colors.black45),
          ),
          if (ready) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              _link.ttsModelDir ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.black38),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final ok = await _link.importTtsModel();
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(ok ? '模型导入成功' : '模型导入失败，详见日志'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  icon: const Icon(Icons.unarchive_outlined, size: 18),
                  label: const Text('导入模型包'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: ready && !_link.synthesizing
                      ? () async {
                          final ok = await _link.synthesizeOpening();
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(ok ? '已生成并设为播报音频' : '合成失败，详见日志'),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      : null,
                  icon: _link.synthesizing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.auto_awesome, size: 18),
                  label: Text(_link.synthesizing ? '合成中…' : '生成语音'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '模型下载：github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models\n'
            '推荐 vits-piper-zh_CN-xiao_ya-medium-int8.tar.bz2（13.4MB），下载后传手机再点「导入模型包」。',
            style: TextStyle(fontSize: 11, height: 1.6, color: Colors.black38),
          ),
        ],
      ),
    );
  }

  Widget _buildAudioCard() {
    final hasAudio = _link.hasAudio;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.audio_file_outlined, size: 18, color: Color(0xFF2F6BFF)),
              const SizedBox(width: 8),
              const Text('开场白音频（推荐）', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: hasAudio ? const Color(0xFFE7F7EE) : const Color(0xFFFDECEC),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  hasAudio ? '已设置' : '未设置',
                  style: TextStyle(
                    fontSize: 11,
                    color: hasAudio ? const Color(0xFF17A05A) : const Color(0xFFD03B3B),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '很多定制系统（小米 HyperOS 等）的系统 TTS 不对第三方应用开放。用一段真人录音播放更稳、更自然，也免去引擎依赖。',
            style: TextStyle(fontSize: 12, height: 1.5, color: Colors.black45),
          ),
          if (hasAudio) ...<Widget>[
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                const Icon(Icons.music_note, size: 14, color: Color(0xFF17A05A)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _link.audioFileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.black87),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final ok = await _link.pickAudio();
                    if (!mounted) return;
                    if (!ok) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('未选择音频文件'), behavior: SnackBarBehavior.floating),
                      );
                    }
                  },
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: Text(hasAudio ? '重新选择' : '选择音频文件'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _link.speak(_scriptController.text),
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('本机试听'),
                ),
              ),
            ],
          ),
          if (hasAudio)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _link.clearAudio,
                child: const Text('清除音频', style: TextStyle(fontSize: 12)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAvatarCard() {
    final enabled = _link.avatarEnabled;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.face_retouching_natural, size: 18, color: Color(0xFF2F6BFF)),
              const SizedBox(width: 8),
              const Text('数字人', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const Spacer(),
              Switch(
                value: enabled,
                onChanged: (v) => _link.setAvatarEnabled(v),
              ),
            ],
          ),
          const Text(
            '播报时数字人会做说话口型，嘴型按语音音量同步。仅本机屏幕可见，对方在通话里看不到画面。',
            style: TextStyle(fontSize: 12, height: 1.5, color: Colors.black45),
          ),
          if (enabled) ...<Widget>[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFEAF0FF),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.open_with, size: 16, color: Color(0xFF2F6BFF)),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '数字人已浮动在屏幕上方，按住底部灰条即可拖动位置，✕ 可关闭。',
                      style: TextStyle(fontSize: 12, height: 1.5, color: Color(0xFF2F6BFF)),
                    ),
                  ),
                  TextButton(
                    onPressed: _link.resetAvatarPosition,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('复位', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '内置样例为 Live2D 官方 Hiyori（仅测试用）。自备模型请打包成 zip（内含 *.model3.json 及其贴图/动作文件），从右上角数字人菜单导入。',
              style: TextStyle(fontSize: 11, height: 1.6, color: Colors.black38),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildScriptCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Icon(Icons.record_voice_over_outlined, size: 18, color: Color(0xFF2F6BFF)),
              SizedBox(width: 8),
              Text('开场白文本（TTS 兜底）', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _scriptController,
            maxLines: 4,
            minLines: 3,
            decoration: const InputDecoration(hintText: '输入接通后要朗读的固定文本'),
            onTapOutside: (_) => _link.setScript(_scriptController.text),
            onSubmitted: (v) => _link.setScript(v),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              const Text('语速', style: TextStyle(fontSize: 12, color: Colors.black54)),
              Expanded(
                child: Slider(
                  value: _link.rate.clamp(0.2, 1.0),
                  min: 0.2,
                  max: 1.0,
                  divisions: 8,
                  label: _link.rate.toStringAsFixed(1),
                  onChanged: (v) => _link.setRate(v),
                ),
              ),
              Text(_link.rate.toStringAsFixed(1), style: const TextStyle(fontSize: 12)),
            ],
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _link.setScript(_scriptController.text),
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('保存文本'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _link.speak(_scriptController.text),
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('本机试听'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _link.hasAudio
                ? '已设置音频，播报时优先播放音频'
                : _link.ttsReady
                    ? '本机 TTS 就绪（未设置音频时用它朗读）'
                    : '本机 TTS 不可用（系统引擎未对第三方开放），请设置开场白音频',
            style: TextStyle(
              fontSize: 11,
              color: (_link.hasAudio || _link.ttsReady) ? const Color(0xFF17A05A) : const Color(0xFFD03B3B),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogCard() {
    final logs = _link.logs;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.receipt_long_outlined, size: 18, color: Color(0xFF2F6BFF)),
              const SizedBox(width: 8),
              const Text('运行日志', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (logs.isNotEmpty)
                TextButton(
                  onPressed: _link.clearLogs,
                  child: const Text('清空', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
          if (logs.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('暂无日志', style: TextStyle(fontSize: 12, color: Colors.black38)),
            )
          else
            ...logs.take(20).map(
                  (log) => Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          log.timeText,
                          style: const TextStyle(fontSize: 11, color: Colors.black38),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            log.message,
                            style: TextStyle(
                              fontSize: 12,
                              color: log.important ? const Color(0xFF2F6BFF) : Colors.black87,
                              fontWeight: log.important ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildTipCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7E6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.info_outline, size: 16, color: Color(0xFFB26A00)),
              SizedBox(width: 6),
              Text(
                '使用要点',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFFB26A00)),
              ),
            ],
          ),
          SizedBox(height: 8),
          Text(
            '1. 两台手机连同一个 Wi-Fi，且都装了本应用\n'
            '2. 拨号端：打开「拨号端」开关，并在系统里开启无障碍权限\n'
            '3. 播放端：只打开「播放端」开关，把手机放在拨号端麦克风旁 5~10cm\n'
            '4. 拨号端建议关闭「AI 通话降噪/人声增强」，否则可能削弱外放声音\n'
            '5. 系统省电策略请设为「无限制/允许后台运行」，避免通话中进程被回收',
            style: TextStyle(fontSize: 12, height: 1.7, color: Color(0xFF8A5A00)),
          ),
        ],
      ),
    );
  }
}
