import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/sheet_data.dart';
import '../services/call_log_store.dart';
import '../services/dialer_service.dart';
import '../services/excel_service.dart';
import '../services/settings_store.dart';
import '../utils/phone_utils.dart';
import '../services/platform_bridge.dart';
import '../widgets/glass_surface.dart';
import 'prompt_page.dart';
import 'record_list_page.dart';
import '../widgets/app_toast.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<ImportedSheet> _sheets = const <ImportedSheet>[];
  int _sheetIndex = 0;
  String _sourceName = '';
  final Set<String> _called = <String>{};
  final TextEditingController _areaCodeController = TextEditingController();
  String _areaCode = PhoneUtils.defaultAreaCode;
  bool _busy = false;

  ImportedSheet? get _currentSheet =>
      _sheetIndex >= 0 && _sheetIndex < _sheets.length ? _sheets[_sheetIndex] : null;

  @override
  void initState() {
    super.initState();
    _areaCodeController.text = _areaCode;
    _restoreCalled();
    _restoreSettings();
  }

  @override
  void dispose() {
    _areaCodeController.dispose();
    super.dispose();
  }

  Future<void> _restoreCalled() async {
    final saved = await CallLogStore.load();
    if (!mounted) return;
    setState(() => _called.addAll(saved));
  }

  Future<void> _restoreSettings() async {
    final saved = await SettingsStore.loadAreaCode();
    if (!mounted) return;
    setState(() {
      _areaCode = saved;
      _areaCodeController.text = saved;
    });
  }

  void _applyAreaCode(String? input) {
    final normalized = PhoneUtils.normalizeAreaCode(input);
    if (normalized == null) {
      _toast('区号格式不对，请输入 021、0755 这样的 3-4 位区号');
      _areaCodeController.text = _areaCode;
      return;
    }
    setState(() {
      _areaCode = normalized;
      _areaCodeController.text = normalized;
    });
    SettingsStore.saveAreaCode(normalized);
  }

  void _toast(String message) {
    if (!mounted) return;
    AppToast.show(context, message);
  }

  Future<void> _importExcel() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        // csv / txt 一并放行：ExcelService 会先尝试按分隔文本解析
        allowedExtensions: const <String>['xlsx', 'xls', 'csv', 'txt'],
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final picked = result.files.single;
      Uint8List? bytes = picked.bytes;
      if (bytes == null && picked.path != null) {
        bytes = await File(picked.path!).readAsBytes();
      }
      if (bytes == null || bytes.isEmpty) {
        throw const ExcelParseException('读取不到文件内容，请换一个文件试试');
      }

      final sheets = ExcelService.parse(bytes, fileName: picked.name);
      final index = _pickBestSheetIndex(sheets);
      if (!mounted) return;
      setState(() {
        _sheets = sheets;
        _sheetIndex = index;
        _sourceName = picked.name;
      });
    } on ExcelParseException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 优先选择「有数据行 + 已识别出手机号列」的工作表
  static int _pickBestSheetIndex(List<ImportedSheet> sheets) {
    var bestIndex = 0;
    var bestScore = -1;
    for (var i = 0; i < sheets.length; i++) {
      final sheet = sheets[i];
      var score = sheet.rowCount;
      if (sheet.phoneColumn != null) score += 100000;
      if (score > bestScore) {
        bestScore = score;
        bestIndex = i;
      }
    }
    return bestIndex;
  }

  void _useDemoData() {
    final sheets = ExcelService.demoSheets();
    setState(() {
      _sheets = sheets;
      _sheetIndex = 0;
      _sourceName = '示例名单（内置）';
    });
  }

  void _selectSheet(int index) {
    setState(() => _sheetIndex = index);
  }

  void _togglePhoneColumn(int column, bool selected) {
    final sheet = _currentSheet;
    if (sheet == null) return;
    final next = selected
        ? (sheet.isPhoneColumn(column) ? sheet.phoneColumns : [...sheet.phoneColumns, column])
        : sheet.phoneColumns.where((c) => c != column).toList();
    final updated = List<ImportedSheet>.of(_sheets);
    updated[_sheetIndex] = sheet.withPhoneColumns(next);
    setState(() => _sheets = updated);
  }

  Future<bool> _dial(String phone) async {
    final target = PhoneUtils.dialTarget(phone, areaCode: _areaCode);
    if (target == null) return false;
    setState(() => _called.add(target));
    CallLogStore.save(_called);
    return DialerService.dial(target);
  }

  void _clearCalled() {
    setState(_called.clear);
    CallLogStore.clear();
  }

  void _openList() {
    final sheet = _currentSheet;
    if (sheet == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecordListPage(
          sheet: sheet,
          called: _called,
          areaCode: _areaCode,
          onCall: _dial,
          onClearCalled: _clearCalled,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sheet = _currentSheet;
    return Scaffold(
      appBar: AppBar(
        title: const Text('话务助手'),
        actions: <Widget>[
          IconButton(
            tooltip: '双机联动播报',
            icon: const Icon(Icons.record_voice_over_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const PromptPage()),
              );
            },
          ),
          if (sheet != null)
            IconButton(
              tooltip: '重新导入',
              icon: const Icon(Icons.refresh),
              onPressed: _busy ? null : _importExcel,
            ),
        ],
      ),
      body: _busy
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在解析表格…', style: TextStyle(color: Colors.black45)),
                ],
              ),
            )
          : sheet == null
              ? _buildEmptyView()
              : _buildDashboard(sheet),
    );
  }

  Widget _buildEmptyView() {
    return Stack(
      children: <Widget>[
        ListView(
          // 底部留白：给悬浮玻璃按钮让位
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 120),
          children: <Widget>[
            Center(
              child: Container(
                width: 104,
            height: 104,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: const <BoxShadow>[
                BoxShadow(color: Color(0x14000000), blurRadius: 24, offset: Offset(0, 10)),
              ],
            ),
            child: const Icon(Icons.table_view, size: 46, color: Color(0xFF2F6BFF)),
          ),
        ),
        const SizedBox(height: 24),
        const Center(
          child: Text('导入 Excel 名单', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 10),
        Center(
          child: Text(
            PlatformBridge.canDial
                ? '自动识别表格中的手机号列，\n点击号码即可跳转系统拨号页并自动填充。'
                : '自动识别表格中的手机号列，\n点击号码即可复制（电脑端没有拨号功能）。',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, height: 1.6, color: Colors.black45),
          ),
        ),
        const SizedBox(height: 32),
        OutlinedButton.icon(
          onPressed: _useDemoData,
          icon: const Icon(Icons.play_circle_outline),
          label: const Text('使用示例名单体验'),
        ),
        const SizedBox(height: 28),
        _buildTipCard(),
          ],
        ),
        // 悬浮液态玻璃主按钮
        Positioned(
          left: 24,
          right: 24,
          bottom: 18,
          child: GlassActionButton(
            onPressed: _importExcel,
            icon: Icons.file_open,
            label: '选择 Excel 文件',
          ),
        ),
      ],
    );
  }

  Widget _buildTipCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Icon(Icons.tips_and_updates_outlined, size: 18, color: Color(0xFFF5A623)),
              SizedBox(width: 6),
              Text('使用说明', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            ],
          ),
          const SizedBox(height: 10),
          const _TipLine(text: '支持 .xlsx / .xls / .csv / .txt（csv、txt 需为逗号或制表符分隔）'),
          const _TipLine(text: '表头含「手机 / 电话 / 手机号码 / phone」等关键词会被优先识别'),
          const _TipLine(text: '号码支持 13800138000、138 0013 8000、+86 13800138000 等写法'),
          if (PlatformBridge.canDial)
            const _TipLine(text: '跳转的是系统拨号页，号码已填好，点拨打键即可呼出')
          else
            const _TipLine(text: '电脑端没有拨号功能，点击号码会复制号码'),
        ],
      ),
    );
  }

  Widget _buildDashboard(ImportedSheet sheet) {
    return Stack(
      children: <Widget>[
        ListView(
          // 底部留白：给悬浮玻璃按钮让位
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 108),
          children: <Widget>[
            // 工作表 / 统计：两卡顶部对齐 + 等高
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(child: _buildSourceCard(sheet)),
                  const SizedBox(width: 10),
                  Expanded(child: _buildStatsCard(sheet)),
                ],
              ),
            ),
            const SizedBox(height: 10),
            // 电话号码列放在固话区号上面
            _buildPhoneColumnCard(sheet),
            const SizedBox(height: 10),
            _buildAreaCodeCard(),
          ],
        ),
        // 悬浮的液态玻璃操作条
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: GlassSurface(
            borderRadius: 28,
            blur: 22,
            opacity: 0.86,
            padding: const EdgeInsets.all(8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: _GlassAction(
                    icon: Icons.upload_file,
                    label: '导入其他表格',
                    primary: false,
                    onTap: _busy ? null : _importExcel,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _GlassAction(
                    icon: Icons.call,
                    label: '开始拨号',
                    primary: true,
                    onTap: _openList,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
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

  Widget _buildSourceCard(ImportedSheet sheet) {
    final multipleSheets = _sheets.length > 1;
    return _card(
      child: InkWell(
        // 名称被截断时，点一下看完整信息
        onTap: () => _showSourceDetail(sheet),
        borderRadius: BorderRadius.circular(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.description_outlined, size: 18, color: Color(0xFF2F6BFF)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _sourceName.isEmpty ? '未命名表格' : _sourceName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                const Icon(Icons.info_outline, size: 15, color: Colors.black26),
              ],
            ),
          const SizedBox(height: 12),
          if (multipleSheets) ...<Widget>[
            const Text('工作表', style: TextStyle(fontSize: 12, color: Colors.black45)),
            const SizedBox(height: 4),
            DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: _sheetIndex,
                isExpanded: true,
                isDense: true,
                items: <DropdownMenuItem<int>>[
                  for (var i = 0; i < _sheets.length; i++)
                    DropdownMenuItem<int>(
                      value: i,
                      child: Text(
                        '${_sheets[i].name}（${_sheets[i].rowCount} 行）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) _selectSheet(value);
                },
              ),
            ),
            const SizedBox(height: 8),
          ] else ...<Widget>[
            Text(
              '工作表：${sheet.name}',
              style: const TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 6),
          ],
          Text(
            sheet.hasHeader ? '表头位于第 ${sheet.headerRow} 行' : '未识别到表头，列名使用 A / B / C 自动编号',
            style: const TextStyle(fontSize: 12, color: Colors.black38),
          ),
          ],
        ),
      ),
    );
  }

  /// 来源表详细信息（文件名被截断时点开看）
  void _showSourceDetail(ImportedSheet sheet) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('表格信息', style: TextStyle(fontSize: 17)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _DetailRow(label: '文件', value: _sourceName.isEmpty ? '未命名表格' : _sourceName),
              _DetailRow(label: '工作表', value: sheet.name),
              _DetailRow(label: '数据行', value: '${sheet.rowCount} 行'),
              _DetailRow(label: '总列数', value: '${sheet.columnCount} 列'),
              _DetailRow(
                label: '表头',
                value: sheet.hasHeader ? '第 ${sheet.headerRow} 行' : '未识别（用 A/B/C 编号）',
              ),
              _DetailRow(
                label: '已选号码列',
                value: sheet.phoneColumns.isEmpty
                    ? '未选择'
                    : sheet.phoneColumns.map((c) => sheet.headerAt(c)).join(' / '),
              ),
              if (_sheets.length > 1)
                _DetailRow(label: '工作表数量', value: '${_sheets.length} 个'),
            ],
          ),
        ),
        actions: <Widget>[
          // 关闭按钮与内容对齐、样式醒目
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
              child: const Text('关闭'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhoneColumnCard(ImportedSheet sheet) {
    final columns = <int>[...sheet.phoneCandidates.map((c) => c.column)];
    for (var i = 0; i < sheet.columnCount; i++) {
      if (!columns.contains(i)) columns.add(i);
    }
    final shown = columns.take(24).toList();
    final selected = sheet.phoneColumns;
    final autoSelected = sheet.phoneCandidates.where((c) => c.autoSelect).length;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.phone_in_talk_outlined, size: 18, color: Color(0xFF2F6BFF)),
              const SizedBox(width: 8),
              const Text('电话号码列', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              const Text('可多选', style: TextStyle(fontSize: 11, color: Colors.black38)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: selected.isEmpty ? const Color(0xFFFDECEC) : const Color(0xFFE7F7EE),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  selected.isEmpty ? '未选择' : '已选 ${selected.length} 列',
                  style: TextStyle(
                    fontSize: 11,
                    color: selected.isEmpty ? const Color(0xFFD03B3B) : const Color(0xFF17A05A),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            selected.isEmpty
                ? '未能自动识别，请手动点选号码所在列（可多选）'
                : autoSelected > 0
                    ? '已自动勾选 $autoSelected 列，可增删；一条记录有多个号码时，拨打会让你选择'
                    : '手动点选号码所在列（可多选）',
            style: const TextStyle(fontSize: 12, color: Colors.black45),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final column in shown)
                FilterChip(
                  label: Text(sheet.headerAt(column)),
                  selected: selected.contains(column),
                  onSelected: (value) => _togglePhoneColumn(column, value),
                  selectedColor: const Color(0xFFE3ECFF),
                  checkmarkColor: const Color(0xFF2F6BFF),
                  labelStyle: TextStyle(
                    fontSize: 13,
                    fontWeight: selected.contains(column) ? FontWeight.w600 : FontWeight.w400,
                    color: selected.contains(column) ? const Color(0xFF2F6BFF) : Colors.black87,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          if (shown.length < columns.length)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('…还有更多列未显示', style: TextStyle(fontSize: 11, color: Colors.black38)),
            ),
        ],
      ),
    );
  }

  Widget _buildAreaCodeCard() {
    const previewLocal = '88886666';
    final preview = PhoneUtils.dialTarget(previewLocal, areaCode: _areaCode);
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.settings_input_component, size: 18, color: Color(0xFF2F6BFF)),
              const SizedBox(width: 8),
              const Text('固话区号', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFE3ECFF),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '当前 $_areaCode',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF2F6BFF)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '座机只写了本地号码（如 88886666）时，拨打会自动补上这个区号；已带区号的号码不受影响。',
            style: TextStyle(fontSize: 12, color: Colors.black45),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final area in PhoneUtils.commonAreaCodes)
                ChoiceChip(
                  label: Text(area.label),
                  selected: area.code == _areaCode,
                  onSelected: (_) => _applyAreaCode(area.code),
                  selectedColor: const Color(0xFFE3ECFF),
                  labelStyle: TextStyle(
                    fontSize: 13,
                    fontWeight: area.code == _areaCode ? FontWeight.w600 : FontWeight.w400,
                    color: area.code == _areaCode ? const Color(0xFF2F6BFF) : Colors.black87,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _areaCodeController,
            keyboardType: TextInputType.number,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(4),
            ],
            onSubmitted: _applyAreaCode,
            onTapOutside: (_) => _applyAreaCode(_areaCodeController.text),
            decoration: const InputDecoration(
              labelText: '自定义区号',
              hintText: '如 021 / 0755',
              prefixIcon: Icon(Icons.edit_outlined, size: 18),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '示例：$previewLocal → ${PhoneUtils.prettyDial(preview)}',
            style: const TextStyle(fontSize: 12, color: Colors.black38),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsCard(ImportedSheet sheet) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Icon(Icons.bar_chart_outlined, size: 18, color: Color(0xFF2F6BFF)),
              SizedBox(width: 8),
              Text('统计', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              _Stat(label: '数据行', value: '${sheet.rowCount}'),
              _Stat(label: '总列数', value: '${sheet.columnCount}'),
              _Stat(label: '已呼叫', value: '${_called.length}'),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: <Widget>[
          Text(
            value,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Color(0xFF2F6BFF)),
          ),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.black45)),
        ],
      ),
    );
  }
}

class _TipLine extends StatelessWidget {
  const _TipLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.only(top: 6, right: 8),
            child: Icon(Icons.circle, size: 5, color: Color(0xFFBFC4CC)),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12, height: 1.5, color: Colors.black54),
            ),
          ),
        ],
      ),
    );
  }
}

/// 详情弹窗里的一行「标签 - 值」
class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 78,
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, color: Colors.black45),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13, color: Colors.black87, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
/// 悬浮玻璃条里的操作按钮
class _GlassAction extends StatelessWidget {
  const _GlassAction({
    required this.icon,
    required this.label,
    required this.primary,
    this.onTap,
  });

  final IconData icon;
  final String label;

  /// 主操作（实心品牌色），次操作为描边
  final bool primary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final foreground = primary ? Colors.white : const Color(0xFF2F6BFF);
    return Material(
      color: primary ? const Color(0xFF2F6BFF) : Colors.white.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: primary
                ? null
                : Border.all(color: const Color(0x332F6BFF), width: 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                icon,
                size: 18,
                color: enabled ? foreground : foreground.withValues(alpha: 0.45),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: enabled ? foreground : foreground.withValues(alpha: 0.45),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
