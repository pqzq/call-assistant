import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/asr_recognizer.dart';
import '../services/call_state_watcher.dart';
import '../services/platform_bridge.dart';
import '../services/avatar_renderer.dart';
import '../services/live2d_service.dart';
import '../services/prompt_link.dart';
import '../widgets/glass_surface.dart';
import '../widgets/confirm_dialog.dart';
import 'demo_page.dart';
import '../widgets/app_toast.dart';
import '../widgets/desktop_body.dart';

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
      AppToast.error(context, '没有可用模型');
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
                trailing: model == _link.avatarModel
                    ? const Icon(Icons.check, size: 18)
                    : (Live2dService.isUserImported(model)
                        // 用户自己导入的模型可以移除，内置的不提供移除
                        ? IconButton(
                            tooltip: '移除这个模型',
                            icon: const Icon(Icons.delete_outline, size: 18),
                            onPressed: () async {
                              // 先取出 navigator，避免 await 之后再跨异步间隙用 context
                              final navigator = Navigator.of(sheetContext);
                              final ok = await _confirmDeleteModel(model);
                              if (ok != true || !mounted) return;
                              await _link.deleteAvatarModel(model);
                              if (!mounted) return;
                              navigator.pop();
                              AppToast.show(context, '已移除模型');
                              // 刷新模型列表
                              final rest = await _link.availableAvatarModels();
                              if (!mounted) return;
                              _showModelPicker(rest);
                            },
                          )
                        : null),
                onTap: () => Navigator.of(sheetContext).pop(model),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) await _link.setAvatarModel(chosen);
  }

  /// 删除确认（只允许删用户导入的模型）
  Future<bool> _confirmDeleteModel(String model) {
    return ConfirmDialog.show(
      context,
      title: '移除模型',
      message: '确定移除「${_modelLabel(model)}」吗？\n该模型占用的文件会一并删除。',
      confirmText: '移除',
      destructive: true,
      icon: Icons.delete_outline,
    );
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
                await _importModel();
              } else if (value == 'importDir') {
                await _importModelFromFolder();
              } else if (value == 'models') {
                await _switchModel();
              } else if (value == 'demo' && _demoSupported) {
                _openDemo();
              }
            },
            itemBuilder: (context) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(
                  value: 'import', child: Text('导入模型包（zip）')),
              const PopupMenuItem<String>(
                  value: 'importDir', child: Text('从文件夹导入模型')),
              const PopupMenuItem<String>(
                  value: 'models', child: Text('切换已有模型')),
              // Windows 不提供演示模式（见 _demoSupported）
              if (_demoSupported)
                const PopupMenuItem<String>(
                    value: 'demo', child: Text('演示模式（全屏）')),
            ],
          ),
          IconButton(
            tooltip: '刷新状态',
            icon: const Icon(Icons.refresh),
            onPressed: () => _link.refreshAccessibility(),
          ),
        ],
      ),
      body: DesktopBody(child: DefaultTabController(
        length: 4,
        child: Stack(
          children: <Widget>[
            Column(
              children: <Widget>[
                // 常驻快捷条：角色开关 + 连接状态 + 立即播报，一屏可达
                _buildQuickBar(),
                Expanded(
                  child: TabBarView(
                    children: <Widget>[
                      _tabView(<Widget>[
                        _buildStatusCard(),
                        const SizedBox(height: 12),
                        _buildDeviceCard(),
                        const SizedBox(height: 12),
                        _buildSingleDeviceCard(),
                      ]),
                      _tabView(<Widget>[
                        _buildScriptCard(),
                        const SizedBox(height: 12),
                        _buildSynthCard(),
                        const SizedBox(height: 12),
                        _buildAudioCard(),
                        const SizedBox(height: 12),
                        _buildAsrCard(),
                      ]),
                      _tabView(<Widget>[
                        _buildAvatarCard(),
                        const SizedBox(height: 12),
                        _buildAvatarModelCard(),
                      ]),
                      _tabView(<Widget>[
                        _buildLogCard(),
                        const SizedBox(height: 16),
                        _buildTipCard(),
                      ]),
                    ],
                  ),
                ),
              ],
            ),
            // 悬浮玻璃导航条
            Positioned(
              left: 16,
              right: 16,
              bottom: 14,
              child: GlassNavBar(
                child: Row(
                  children: <Widget>[
                    _navItem(0, Icons.link, '连接'),
                    _navItem(1, Icons.campaign_outlined, '播报'),
                    _navItem(2, Icons.face_retouching_natural, '数字人'),
                    _navItem(3, Icons.receipt_long_outlined, '日志'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      ),   // DesktopBody
    );
  }

  /// 玻璃导航条上的一个项
  Widget _navItem(int index, IconData icon, String label) {
    return Expanded(
      child: Builder(
        builder: (context) {
          final controller = DefaultTabController.of(context);
          return AnimatedBuilder(
            animation: controller,
            builder: (context, _) => GlassNavItem(
              selected: controller.index == index,
              icon: icon,
              label: label,
              onTap: () => controller.animateTo(index),
            ),
          );
        },
      ),
    );
  }

  /// 数字人模型与展示入口
  Widget _buildAvatarModelCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Icon(Icons.face_retouching_natural, size: 18, color: Color(0xFF2F6BFF)),
              SizedBox(width: 8),
              Text('模型与展示', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '当前模型：${_link.avatarModel}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 10),
          // 渲染后端切换：WebView（全平台） / 原生（仅 Android、iOS）
          Row(
            children: <Widget>[
              const Text('渲染引擎', style: TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(width: 8),
              Expanded(
                child: SegmentedButton<AvatarBackend>(
                  segments: <ButtonSegment<AvatarBackend>>[
                    for (final backend in AvatarBackend.values)
                      ButtonSegment<AvatarBackend>(
                        value: backend,
                        // 当前平台不支持的直接置灰（如 Windows 上的原生渲染）
                        enabled: backendUnsupportedReason(backend) == null,
                        label: Text(backend.displayName, style: const TextStyle(fontSize: 12)),
                        tooltip: backendUnsupportedReason(backend) ?? backend.displayName,
                      ),
                  ],
                  selected: <AvatarBackend>{_link.avatarBackend},
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    minimumSize: const Size(0, 34),
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                  onSelectionChanged: (selection) async {
                    final backend = selection.first;
                    final reason = backendUnsupportedReason(backend);
                    if (reason != null) {
                      AppToast.error(context, reason);
                      return;
                    }
                    await _link.setAvatarBackend(backend);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 模型大小：Live2D 的 canvas 四周留白各模型差异很大，自动适配
          // 常出现「有的显得太小」，这里开放给用户微调。
          // 原生渲染暂不支持（放大参数在 C++ 侧固定），只对 WebView 生效。
          Row(
            children: <Widget>[
              const Text('模型大小',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
              Expanded(
                child: Slider(
                  value: _link.avatarModelZoom.clamp(0.8, 1.8).toDouble(),
                  min: 0.8,
                  max: 1.8,
                  divisions: 20,
                  label: '${_link.avatarModelZoom.toStringAsFixed(2)}x',
                  // 拖动过程只更新内存（不写磁盘），松手才持久化
                  onChanged: (v) => _link.setAvatarModelZoom(v, persist: false),
                  onChangeEnd: (v) => _link.setAvatarModelZoom(v),
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  '${_link.avatarModelZoom.toStringAsFixed(2)}x',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
            ],
          ),
          const Text(
            '1.00x 为自动适配；调大会放大，超出的部分从脚部裁掉（不会挡脸）。两种渲染引擎都生效。',
            style: TextStyle(fontSize: 11, color: Colors.black38, height: 1.4),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _modelButton('切换模型', Icons.swap_horiz, _switchModel),
              _modelButton('导入 zip', Icons.folder_open, _importModel),
              _modelButton('导入文件夹', Icons.folder_copy_outlined, _importModelFromFolder),
              if (_demoSupported)
              _modelButton('演示模式', Icons.fullscreen, _openDemo),
              _modelButton('复位位置', Icons.my_location, _link.resetAvatarPosition),
            ],
          ),
        ],
      ),
    );
  }

  /// 模型操作按钮（两列排布）
  Widget _modelButton(String label, IconData icon, VoidCallback onTap) {
    return SizedBox(
      width: (MediaQuery.of(context).size.width - 32 - 32 - 8) / 2,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 17),
        label: Text(label, style: const TextStyle(fontSize: 13)),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      ),
    );
  }

  /// 导入模型包（zip）
  Future<void> _importModel() async {
    final ok = await _link.importAvatarModel();
    if (!mounted) return;
    if (ok) {
      AppToast.show(context, '数字人模型已导入', icon: Icons.check_circle_outline);
    } else {
      AppToast.error(context, '导入失败，详见日志');
    }
  }

  /// 从文件夹导入模型
  Future<void> _importModelFromFolder() async {
    final ok = await _link.importAvatarModelFromFolder();
    if (!mounted) return;
    if (ok) {
      AppToast.show(context, '模型已从文件夹导入', icon: Icons.check_circle_outline);
      return;
    }
    final reason = _link.lastImportError;
    final needPermission = reason == null && !await CallStateWatcher.hasAllFilesAccess();
    if (!mounted) return;
    if (needPermission) {
      // 权限没开：引导去系统设置开启后再试
      AppToast.show(
        context,
        '请在系统设置里开启「所有文件访问权限」，然后重新导入',
        icon: Icons.open_in_new,
      );
      return;
    }
    AppToast.error(context, reason ?? '导入失败');
  }

  /// 切换已有模型
  Future<void> _switchModel() async {
    final models = await _link.availableAvatarModels();
    if (!mounted) return;
    _showModelPicker(models);
  }

  /// 演示模式是否可用
  ///
  /// **Windows 上不提供**：演示页会再创建**第二个**数字人实例，和左栏分栏
  /// 同时存在时两者互相影响 —— 实测演示页一直是空白（纯白、无提示），
  /// 而左栏单独用又是正常的。与其留一个「点了就空白」的入口，
  /// 不如在 Windows 上直接隐藏它（其他平台保留，那边没有分栏布局）。
  bool get _demoSupported => !PlatformBridge.isWindows;

  /// 打开全屏演示模式
  void _openDemo() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const DemoPage()),
    );
  }

  /// 标签页内容（各自可滚动，但关键操作都在首屏）
  Widget _tabView(List<Widget> children) {
    return ListView(
      // 底部留白：避免被悬浮玻璃导航条遮住
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: children,
    );
  }

  /// 常驻快捷条：角色开关 + 连接状态 + 立即播报
  Widget _buildQuickBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              // 桌面端（PC）只做播放端：没有系统拨号能力，也不存在「拨号端」角色
              if (PlatformBridge.canDetectCall) ...<Widget>[
                _roleChip(
                  label: '拨号端',
                  icon: Icons.phone_in_talk,
                  on: _link.autoTrigger,
                  onChanged: (v) => _link.setAutoTrigger(v),
                ),
                const SizedBox(width: 8),
              ],
              _roleChip(
                label: '播放端',
                icon: Icons.volume_up,
                on: _link.asPlayer,
                onChanged: (v) => _link.setAsPlayer(v),
              ),
              const SizedBox(width: 10),
              Expanded(child: _buildConnChip()),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  onPressed: _link.triggerManually,
                  icon: const Icon(Icons.campaign_outlined, size: 18),
                  label: const Text('立即播报'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(40),
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _link.interruptSpeaking,
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: const Text('停止', style: TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  foregroundColor: const Color(0xFFD03B3B),
                  side: const BorderSide(color: Color(0x33D03B3B)),
                ),
              ),
              // 只有「拨号端」才需要通话检测，未开启拨号端时不显示这个按钮
              if (_link.autoTrigger && !_link.accessibilityEnabled) ...<Widget>[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    await PlatformBridge.openAccessibilitySettings();
                  },
                  icon: const Icon(Icons.warning_amber_rounded, size: 16, color: Color(0xFFE08A00)),
                  label: const Text('开启检测', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ],
            ],
          ),
          if (_link.armed) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '等待接通中：${_link.armedLabel} ${_link.armedPhone}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFF2F6BFF)),
            ),
          ],
        ],
      ),
    );
  }

  /// 角色开关胶囊
  Widget _roleChip({
    required String label,
    required IconData icon,
    required bool on,
    required ValueChanged<bool> onChanged,
  }) {
    return GestureDetector(
      onTap: () => onChanged(!on),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: on ? const Color(0xFF2F6BFF) : const Color(0xFFF0F2F6),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 14, color: on ? Colors.white : const Color(0xFF8A94A6)),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: on ? Colors.white : const Color(0xFF6B7688),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 连接状态 + 手动连接按钮
  Widget _buildConnChip() {
    final text = _link.peerConnected
        ? '已连接 ${_link.connectedPeerName ?? '对端'}'
        : _link.seeking
            ? '正在寻找拨号端…'
            : _link.listening
                ? (_link.asPlayer ? '等待手机拨号端连接' : '等待播放端连接')
                : '局域网未启动';
    final color = _link.peerConnected
        ? const Color(0xFF17A05A)
        : _link.listening
            ? const Color(0xFF2F6BFF)
            : Colors.black38;
    if (_link.asPlayer && _link.listening) {
      return TextButton(
        onPressed: _link.peerConnected ? _link.disconnectPeer : _link.connectToDialer,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(
          _link.peerConnected ? '断开' : (_link.seeking ? '搜索中…' : '连接拨号端'),
          style: const TextStyle(fontSize: 12),
        ),
      );
    }
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12, color: color),
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
    // 桌面端没有无障碍服务（也不存在「拨号端」角色），整张卡片不显示
    if (!PlatformBridge.canDetectCall) return const SizedBox.shrink();
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
                await PlatformBridge.openAccessibilitySettings();
              },
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('打开系统无障碍设置'),
            ),
          ],
          if (_link.lastError != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(_link.lastError!, style: const TextStyle(fontSize: 12, color: Color(0xFFD03B3B))),
          ],
        ],
      ),
    );
  }

  /// 设备名（角色开关与播报按钮已移到顶部快捷条）
  Widget _buildDeviceCard() {
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
          const SizedBox(height: 6),
          const Text(
            '拨号端：本机拨打电话，检测到对方接通后广播播报指令。\n'
            '播放端：放在拨号手机旁边，用它来朗读（建议固定支架、对准麦克风）。',
            style: TextStyle(fontSize: 12, height: 1.5, color: Colors.black45),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: '设备名（另一台手机看到的名字）',
              isDense: true,
            ),
            onSubmitted: (v) => _link.setDeviceName(v),
            onTapOutside: (_) => _link.setDeviceName(_nameController.text),
          ),
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
                    if (ok) {
                      AppToast.show(context, '模型导入成功');
                    } else {
                      AppToast.error(context, '模型导入失败，详见日志');
                    }
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
                          if (ok) {
                            AppToast.show(context, '已生成并设为播报音频');
                          } else {
                            AppToast.error(context, '合成失败，详见日志');
                          }
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
          // 下载地址可点击跳转
          GestureDetector(
            onTap: () => _openUrl('https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models'),
            child: const Text(
              '模型下载：github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models（点击打开）\n'
              '推荐 vits-piper-zh_CN-xiao_ya-medium-int8.tar.bz2（13.4MB），下载后传手机再点「导入模型包」。',
              style: TextStyle(
                fontSize: 11,
                height: 1.6,
                color: Color(0xFF2F6BFF),
                decoration: TextDecoration.underline,
                decorationColor: Color(0x332F6BFF),
              ),
            ),
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
                      AppToast.error(context, '未选择音频文件');
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
          const SizedBox(height: 10),
          // 用离线语音识别把这段录音转成文本
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: hasAudio ? _recognizeToText : null,
              icon: const Icon(Icons.record_voice_over_outlined, size: 18),
              label: const Text('把这段音频转成文本'),
            ),
          ),
          if (hasAudio && !_link.asrModelReady)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '需要先在下方「语音识别模型」里导入模型',
                style: const TextStyle(fontSize: 11, color: Color(0xFFE08A00)),
              ),
            ),
        ],
      ),
    );
  }

  /// 语音识别模型卡片：导入模型 + 下载链接
  Widget _buildAsrCard() {
    final ready = _link.asrModelReady;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.multitrack_audio, size: 18, color: Color(0xFF2F6BFF)),
              const SizedBox(width: 8),
              const Text('语音识别模型', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: ready ? const Color(0xFFE7F7EE) : const Color(0xFFFDECEC),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  ready ? '已安装' : '未安装',
                  style: TextStyle(
                    fontSize: 11,
                    color: ready ? const Color(0xFF17A05A) : const Color(0xFFD03B3B),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            ready
                ? '当前模型：${_link.asrModelName}'
                : '把「开场白音频」转成文本需要离线语音识别模型（SenseVoice，约 155MB）。'
                    '模型只在本机运行，录音不会上传。',
            style: const TextStyle(fontSize: 12, height: 1.5, color: Colors.black45),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _importAsrModel,
                  icon: const Icon(Icons.upload_file, size: 18),
                  label: const Text('导入模型包'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _openUrl(AsrRecognizer.modelDownloadPage),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('下载模型'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '模型包：sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2\n'
            '（tar.bz2 格式，导入后自动识别，无需手动解压）',
            style: TextStyle(fontSize: 11, height: 1.6, color: Colors.black38),
          ),
        ],
      ),
    );
  }

  /// 导入语音识别模型
  Future<void> _importAsrModel() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: false,
    );
    if (!mounted) return;
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) {
      AppToast.error(context, '无法读取所选模型包');
      return;
    }
    final ok = await _link.importAsrModel(File(path));
    if (!mounted) return;
    if (ok) {
      AppToast.show(context, '语音识别模型已导入', icon: Icons.check_circle_outline);
    } else {
      AppToast.error(context, '导入失败，详见日志');
    }
  }

  /// 识别当前开场白音频 -> 弹出结果（可编辑）-> 填入文本框
  Future<void> _recognizeToText() async {
    final text = await _link.recognizeOpeningAudio();
    if (!mounted) return;
    if (text == null) {
      AppToast.error(context, '识别失败，详见日志');
      return;
    }
    final controller = TextEditingController(text: text);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('识别结果', style: TextStyle(fontSize: 17)),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: controller,
            // 不自动弹键盘：否则弹窗被顶起来，按钮位置会变
            autofocus: false,
            maxLines: 6,
            minLines: 3,
            decoration: const InputDecoration(
              hintText: '识别出的文本，可以直接修改',
              isDense: true,
            ),
          ),
        ),
        actions: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                    foregroundColor: const Color(0xFF5B6B84),
                    side: const BorderSide(color: Color(0xFFD7DEE9)),
                  ),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                  child: const Text('填入'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    final value = controller.text.trim();
    if (value.isEmpty) return;
    _scriptController.text = value;
    setState(() {});
    AppToast.show(context, '已填入开场白文本', icon: Icons.check_circle_outline);
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
                      '数字人已浮在屏幕上方：按住数字人本体或左侧操作栏最上面的 ⠿ 手柄即可拖动；'
                      '左侧操作栏最下面的红色 ✕ 关闭。',
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
              '内置样例为 Live2D 官方 Hiyori（仅测试用）。自备模型请打包成 zip'
              '（内含 *.model3.json 及其贴图/动作文件），在上面「模型与展示」里点'
              '「导入 zip」或「导入文件夹」。',
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

  Widget _buildSingleDeviceCard() {
    final on = _link.singleDeviceTest;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.smartphone, size: 18, color: Color(0xFF2F6BFF)),
              const SizedBox(width: 8),
              const Text('单机自测', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const Spacer(),
              Switch(
                value: on,
                onChanged: (v) => _link.setSingleDeviceTest(v),
              ),
            ],
          ),
          Text(
            on
                ? '本机同时扮演拨号端与播放端：点「连接拨号端」即可自连，随后拨号能完整走通「接通 → 广播 → 朗读 → 口型」全链路。'
                : '只有一台手机时打开它，就能模拟出另一台手机，不用真机对测就能验证整条播报链路。',
            style: const TextStyle(fontSize: 12, height: 1.5, color: Colors.black45),
          ),
        ],
      ),
    );
  }

  /// 打开外部链接（模型下载页等）
  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      AppToast.error(context, '无法打开链接');
    }
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
            '2. 拨号端：点顶部「拨号端」胶囊打开，并在系统里开启无障碍权限\n'
            '3. 播放端：点顶部「播放端」胶囊打开，再点「连接拨号端」完成配对\n'
            '4. 把播放端手机放在拨号端麦克风旁 5~10cm，音量 60~80%\n'
            '5. 拨号端建议关闭「AI 通话降噪/人声增强」，否则可能削弱外放声音\n'
            '6. 系统省电策略请设为「无限制/允许后台运行」，避免通话中进程被回收',
            style: TextStyle(fontSize: 12, height: 1.7, color: Color(0xFF8A5A00)),
          ),
        ],
      ),
    );
  }
}
