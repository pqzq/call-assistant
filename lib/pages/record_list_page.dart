import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:file_picker/file_picker.dart';

import '../models/active_lead.dart';
import '../models/sheet_data.dart';
import '../services/call_log_store.dart';
import '../services/call_state_watcher.dart';
import '../services/excel_service.dart';
import '../services/prompt_link.dart';
import '../utils/phone_utils.dart';
import '../widgets/record_card.dart';
import '../widgets/app_toast.dart';
import '../widgets/confirm_dialog.dart';
import 'prompt_page.dart';

class RecordListPage extends StatefulWidget {
  const RecordListPage({
    super.key,
    required this.sheet,
    required this.called,
    required this.areaCode,
    required this.onCall,
    required this.onClearCalled,
  });

  final ImportedSheet sheet;

  /// 已呼叫的号码（进入页面时的快照）
  final Set<String> called;

  /// 固话缺区号时补全使用的区号，例如 021
  final String areaCode;

  /// 点击号码时回调，返回 true 表示号码已生效
  final Future<bool> Function(String phone) onCall;

  final VoidCallback onClearCalled;

  @override
  State<RecordListPage> createState() => _RecordListPageState();
}

class _RecordListPageState extends State<RecordListPage> {
  final TextEditingController _controller = TextEditingController();
  final Set<String> _called = <String>{};
  String _query = '';

  /// 紧凑模式（默认开启）：一屏能看到更多行
  bool _compact = true;

  static const String _compactKey = 'record_list_compact';

  /// 最近拨打的行（持续高亮，直到刷新列表 / 重新进入本页）
  int? _highlightRow;

  /// 本地表格副本：写入「拨打情况」后用它刷新界面
  late ImportedSheet _sheet;

  @override
  void initState() {
    super.initState();
    _called.addAll(widget.called);
    _sheet = widget.sheet.ensureStatusColumn();
    _loadCompactPref();
    _loadStatusPrefs();
  }

  /// 读取上次保存的拨打情况（按 表格名|行号 存储）
  Future<void> _loadStatusPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var changed = false;
      var next = _sheet;
      for (var row = 0; row < next.rowCount; row++) {
        final value = prefs.getString(_statusKey(row));
        if (value == null || value.isEmpty) continue;
        next = next.withStatusAt(row, value);
        changed = true;
      }
      if (changed && mounted) setState(() => _sheet = next);
    } catch (_) {
      // 忽略
    }
  }

  String _statusKey(int row) => 'record_status|${_sheet.name}|$row';

  /// 写入拨打情况（同时落地到本地，下次进入仍在）
  Future<void> _setStatus(int row, String value) async {
    setState(() => _sheet = _sheet.withStatusAt(row, value));
    try {
      final prefs = await SharedPreferences.getInstance();
      if (value.isEmpty) {
        await prefs.remove(_statusKey(row));
      } else {
        await prefs.setString(_statusKey(row), value);
      }
    } catch (_) {
      // 忽略
    }
    if (!mounted) return;
    AppToast.show(context, value.isEmpty ? '已清空拨打情况' : '已标记：$value');
  }

  /// 读取上次选择的显示密度
  Future<void> _loadCompactPref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getBool(_compactKey);
      if (value == null || !mounted) return;
      setState(() => _compact = value);
    } catch (_) {
      // 忽略
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _markDialing(int row) {
    if (!mounted) return;
    setState(() => _highlightRow = row);
  }

  /// 刷新列表：清除高亮（已呼叫标记保留）
  void _resetHighlight() {
    setState(() => _highlightRow = null);
  }

  List<int> _visibleRows() {
    final sheet = _sheet;
    final keyword = _query.trim().toLowerCase();
    if (keyword.isEmpty) {
      return List<int>.generate(sheet.rowCount, (index) => index);
    }
    final result = <int>[];
    for (var row = 0; row < sheet.rowCount; row++) {
      for (final cell in sheet.rows[row]) {
        if (cell.toLowerCase().contains(keyword)) {
          result.add(row);
          break;
        }
      }
    }
    return result;
  }

  /// 非号码列的其它字段（所有选中的号码列都要排除）
  List<CellField> _fieldsOf(int row) {
    final sheet = _sheet;
    final fields = <CellField>[];
    for (var column = 0; column < sheet.columnCount; column++) {
      if (sheet.isPhoneColumn(column)) continue;
      final value = sheet.cellAt(row, column).trim();
      if (value.isEmpty) continue;
      fields.add(CellField(sheet.headerAt(column).trim(), value));
    }
    return fields;
  }

  /// 卡片上展示的字段：去掉标题本身与「序号」项
  List<CellField> _displayFields(List<CellField> fields, int titleIndex) {
    return <CellField>[
      for (var i = 0; i < fields.length; i++)
        if (i != titleIndex && fields[i].label != '序号') fields[i],
    ];
  }

  static final RegExp _pureNumber = RegExp(r'^\d+$');

  /// 标题取第一个「非纯数字」且靠前的字段（跳过「序号」这类列）
  int _titleIndexOf(List<CellField> fields) {
    if (fields.isEmpty) return -1;
    for (var i = 0; i < fields.length; i++) {
      if (!_pureNumber.hasMatch(fields[i].value.trim())) return i;
    }
    return 0;
  }

  String _titleText(CellField? field, int row) {
    if (field == null) return '第 ${row + 1} 行';
    final text = field.value.replaceAll(RegExp(r'\s+'), ' ');
    return text.length > 24 ? '${text.substring(0, 24)}…' : text;
  }

  /// 把当前行整理成提词用的客户信息（含上次拨打时间）
  Future<void> _attachLead(int row, String phone) async {
    final fields = _fieldsOf(row);
    final titleIndex = _titleIndexOf(fields);
    final name = titleIndex >= 0 ? fields[titleIndex].value.trim() : '第 ${row + 1} 行';
    // 提词气泡里不占用「序号」的位置（展示部门/备注更有用）
    final extras = _displayFields(fields, titleIndex);
    Map<String, DateTime> times = <String, DateTime>{};
    try {
      times = await CallLogStore.loadTimes();
    } catch (_) {
      // 忽略
    }
    await PromptLink.instance.setActiveLead(ActiveLead(
      name: name.isEmpty ? '第 ${row + 1} 行' : name,
      phone: phone,
      extras: extras,
      lastCalled: times[phone],
    ));
  }

  /// 联动日志用的行描述：标题 + 号码
  String _rowLabelOf(int row) {
    final fields = _fieldsOf(row);
    final titleIndex = _titleIndexOf(fields);
    final title = titleIndex >= 0 ? fields[titleIndex].value : '第 ${row + 1} 行';
    final phone = PhoneUtils.dialTarget(_sheet.rawPhoneAt(row), areaCode: widget.areaCode);
    return phone == null ? title : '$title $phone';
  }

  Future<void> _dialEntry(PhoneEntry entry, int row) async {
    final target = entry.dialTarget;
    if (target == null) {
      _toast('号码格式无法识别');
      return;
    }
    _markDialing(row);
    setState(() => _called.add(target));
    HapticFeedback.lightImpact();
    // 浮动提词气泡：把当前客户与上次联系时间带过去
    await _attachLead(row, target);
    // 双机联动：拨号后进入「等待接通」状态，接通即通知播放端
    PromptLink.instance.armAfterDial(rowLabel: _rowLabelOf(row), phone: target);
    final ok = await widget.onCall(target);
    if (!ok) {
      _toast('未找到可用的拨号应用');
    }
  }

  /// 多个号码时先弹出选择器，单个号码直接拨打
  Future<void> _chooseAndDial(List<PhoneEntry> phones, int row) async {
    if (phones.isEmpty) {
      _toast('该行没有可用号码');
      return;
    }
    if (phones.length == 1) {
      await _dialEntry(phones.first, row);
      return;
    }
    final chosen = await showModalBottomSheet<PhoneEntry>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _NumberPickerSheet(
        title: '选择要拨打的号码',
        phones: phones,
        called: _called,
      ),
    );
    if (chosen != null) {
      await _dialEntry(chosen, row);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    AppToast.show(context, message);
  }

  Future<void> _copyAll() async {
    final sheet = _sheet;
    final buffer = StringBuffer();
    for (var row = 0; row < sheet.rowCount; row++) {
      final phones = sheet.phonesAt(row, widget.areaCode).where((p) => p.valid).toList();
      if (phones.isEmpty) continue;
      buffer.write('${phones.map((p) => p.display).join('、')}\n');
    }
    final text = buffer.toString().trim();
    if (text.isEmpty) {
      _toast('没有可复制的号码');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _toast('已复制全部号码');
  }

  /// 导出为 xlsx：表头 + 全部数据行，拨打情况在最后一列并已填充
  Future<void> _exportXlsx() async {
    try {
      final bytes = ExcelService.exportToXlsx(_sheet);
      if (bytes.isEmpty) {
        if (!mounted) return;
        AppToast.error(context, '导出失败：生成的文件为空');
        return;
      }
      final stamp = DateTime.now().toString().replaceAll(RegExp(r'[:. ]'), '-').substring(0, 19);
      final base = _sheet.name.isEmpty ? '名单' : _sheet.name;
      final fileName = '${base}_拨打情况_$stamp.xlsx';

      // 首选：直接存到系统「下载」目录（MediaStore，不需要权限，也不会被系统对话框坑到）
      final saved = await CallStateWatcher.saveToDownloads(fileName, bytes);
      if (!mounted) return;
      if (saved != null) {
        AppToast.show(context, '已保存到：$saved', icon: Icons.check_circle_outline);
        return;
      }

      // 兜底：系统「另存为」对话框
      final picked = await FilePicker.platform.saveFile(
        dialogTitle: '保存导出的表格',
        fileName: fileName,
        bytes: bytes,
      );
      if (!mounted) return;
      if (picked == null) return; // 用户取消
      AppToast.show(context, '已导出：$fileName', icon: Icons.check_circle_outline);
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, '导出失败：$e');
    }
  }

  /// 清空所有行的拨打情况（含本地存储）
  Future<void> _clearAllStatus() async {
    final ok = await ConfirmDialog.show(
      context,
      title: '清空拨打情况',
      message: '将清空当前表格所有行的拨打情况，确定继续？',
      confirmText: '清空',
      destructive: true,
      icon: Icons.delete_sweep_outlined,
    );
    if (!ok) return;

    var next = _sheet;
    for (var row = 0; row < next.rowCount; row++) {
      next = next.withStatusAt(row, '');
    }
    setState(() => _sheet = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      for (var row = 0; row < next.rowCount; row++) {
        await prefs.remove(_statusKey(row));
      }
    } catch (_) {
      // 忽略
    }
    if (!mounted) return;
    AppToast.show(context, '已清空所有拨打情况');
  }

  @override
  Widget build(BuildContext context) {
    final sheet = _sheet;
    final rows = _visibleRows();

    return Scaffold(
      appBar: AppBar(
        title: Text(sheet.name.isEmpty ? '号码列表' : sheet.name),
        actions: <Widget>[
          // 双机联动快捷跳转（放在排版按钮左边）
          IconButton(
            tooltip: '双机联动播报',
            icon: const Icon(Icons.record_voice_over_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const PromptPage()),
              );
            },
          ),
          IconButton(
            tooltip: _compact ? '切换为详细模式' : '切换为紧凑模式',
            icon: Icon(_compact ? Icons.view_agenda_outlined : Icons.density_small),
            onPressed: () async {
              setState(() => _compact = !_compact);
              try {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool(_RecordListPageState._compactKey, _compact);
              } catch (_) {
                // 忽略
              }
            },
          ),
          IconButton(
            tooltip: '刷新列表',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _resetHighlight();
              _toast('列表已刷新');
            },
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (value) {
              if (value == 'copy') {
                _copyAll();
              } else if (value == 'refresh') {
                _resetHighlight();
                _toast('列表已刷新');
              } else if (value == 'clear') {
                setState(_called.clear);
                widget.onClearCalled();
                _toast('已清空呼叫标记');
              } else if (value == 'export') {
                _exportXlsx();
              } else if (value == 'clearStatus') {
                _clearAllStatus();
              }
            },
            itemBuilder: (context) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'export', child: Text('导出为 xlsx（含拨打情况）')),
              PopupMenuItem<String>(value: 'clearStatus', child: Text('清空所有拨打情况')),
              PopupMenuItem<String>(value: 'refresh', child: Text('刷新列表（清除高亮）')),
              PopupMenuItem<String>(value: 'copy', child: Text('复制全部号码')),
              PopupMenuItem<String>(value: 'clear', child: Text('清空呼叫标记')),
            ],
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _controller,
              onChanged: (value) => setState(() => _query = value),
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: '搜索姓名 / 号码 / 其他字段',
                hintStyle: const TextStyle(fontSize: 13),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                prefixIcon: const Icon(Icons.search, size: 18),
                prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 30),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 16),
                        onPressed: () {
                          _controller.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child:                   Text(
                    '共 ${sheet.rowCount} 条 · 长按看详情',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: Colors.black45),
                  ),
                ),
                Text(
                  !sheet.hasPhoneColumn
                      ? '未选择号码列'
                      : sheet.phoneColumns.length == 1
                          ? '号码列：${sheet.headerAt(sheet.phoneColumn!)}'
                          : '号码列：${sheet.phoneColumns.map(sheet.headerAt).join(' / ')}',
                  style: const TextStyle(fontSize: 11.5, color: Colors.black45),
                ),
              ],
            ),
          ),
          Expanded(
            child: !sheet.hasPhoneColumn
                ? const _Notice(
                    icon: Icons.search_off,
                    title: '还没有选择号码列',
                    message: '返回上一页，勾选号码所在列（可多选）后再开始拨号。',
                  )
                : rows.isEmpty
                    ? const _Notice(
                        icon: Icons.inbox_outlined,
                        title: '没有匹配的记录',
                        message: '换个关键词试试，或检查表格内容是否为空。',
                      )
                    : _buildList(rows),
          ),
        ],
      ),
    );
  }

  /// 该行完整信息（卡片里被省略的内容在这里看全）
  void _showRowDetail(int row, List<CellField> fields, List<PhoneEntry> phones) {
    final titleIndex = _titleIndexOf(fields);
    final name = titleIndex >= 0 ? fields[titleIndex].value.trim() : '第 ${row + 1} 行';
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        // 内容自适应高度：内容少时弹窗就矮，不会留大片空白；
        // 内容多时最多占 80% 并可滚动
        child: Padding(
          padding: const EdgeInsets.only(top: 36),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.8,
            ),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
              Text(
                name.isEmpty ? '第 ${row + 1} 行' : name,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              if (phones.isNotEmpty) ...<Widget>[
                const Text(
                  '号码',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black45),
                ),
                const SizedBox(height: 6),
                for (final phone in phones)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SizedBox(
                          width: 86,
                          child: Text(
                            phone.label,
                            style: const TextStyle(fontSize: 13, color: Colors.black45),
                          ),
                        ),
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              _dialEntry(phone, row);
                            },
                            child: Text(
                              phone.display,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF1B62F0),
                              ),
                            ),
                          ),
                        ),
                        if (phone.note != null && phone.note!.isNotEmpty)
                          Text(
                            phone.note!,
                            style: const TextStyle(fontSize: 11, color: Color(0xFF17A05A)),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
              ],
              const Text(
                '其它字段',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black45),
              ),
              const SizedBox(height: 6),
              // 双列排布，字段多时也不会把弹窗撑得很高
              Wrap(
                spacing: 12,
                runSpacing: 6,
                children: <Widget>[
                  for (final field in fields)
                    SizedBox(
                      width: (MediaQuery.of(sheetContext).size.width - 52) / 2,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          SizedBox(
                            width: 54,
                            child: Text(
                              field.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12.5, color: Colors.black45),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              field.value,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12.5, color: Colors.black87, height: 1.35),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              // 拨打情况：快捷选项 + 自定义填写，写回表格末尾的「拨打情况」列
              _StatusSection(
                current: _sheet.statusAt(row),
                onPick: (value) {
                  Navigator.of(sheetContext).pop();
                  _setStatus(row, value);
                },
                onCustom: () async {
                  Navigator.of(sheetContext).pop();
                  await _promptCustomStatus(row);
                },
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  _chooseAndDial(phones, row);
                },
                icon: const Icon(Icons.call, size: 18),
                label: const Text('拨打该行号码'),
              ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 自定义填写拨打情况
  Future<void> _promptCustomStatus(int row) async {
    final controller = TextEditingController(text: _sheet.statusAt(row));
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('填写拨打情况', style: TextStyle(fontSize: 17)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 2,
          minLines: 1,
          decoration: const InputDecoration(
            hintText: '例如：客户说下周一再联系',
            isDense: true,
          ),
        ),
        actions: <Widget>[
          // 取消与保存同一行、同样大小，确认按钮更醒目
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
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
                  onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                  child: const Text('保存'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (value == null || value.isEmpty) return;
    await _setStatus(row, value);
  }
  /// 紧凑模式用两列网格（一次能看到更多记录），详细模式保持单列
  Widget _buildList(List<int> rows) {
    final sheet = _sheet;

    Widget buildItem(BuildContext context, int index) {
      final row = rows[index];
      final fields = _fieldsOf(row);
      final titleIndex = _titleIndexOf(fields);
      // 卡片上不展示「序号」项（长按详情里仍能看到完整字段）
      final details = _displayFields(fields, titleIndex);
      final phones = sheet.phonesAt(row, widget.areaCode);
      final anyCalled = phones.any(
        (p) => p.dialTarget != null && _called.contains(p.dialTarget),
      );
      return RecordCard(
        key: ValueKey<String>('row_$row'),
        rowNumber: row + 1,
        title: _titleText(titleIndex >= 0 ? fields[titleIndex] : null, row),
        phones: phones,
        fields: details,
        called: anyCalled,
        highlighted: _highlightRow == row,
        compact: _compact,
        narrow: _compact,
        status: _sheet.statusAt(row),
        onTap: () => _chooseAndDial(phones, row),
        onPhoneTap: (entry) => _dialEntry(entry, row),
        onMoreTap: () => _showRowDetail(row, fields, phones),
      );
    }

    if (_compact) {
      // 双列网格：一次能看到两倍的记录
      return GridView.builder(
        // 左右留白收紧 -> 每列更宽，号码不容易换行
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 24),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 5,
          crossAxisSpacing: 4,
          // 高度只够「姓名 + 号码 + 拨打情况」展示，尽量一屏多看几行
          mainAxisExtent: 84,
        ),
        itemCount: rows.length,
        itemBuilder: buildItem,
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      itemCount: rows.length,
      itemBuilder: buildItem,
    );
  }
}

/// 多号码时的拨号选择面板
/// 拨打情况设置：快捷选项 + 自定义填写
class _StatusSection extends StatelessWidget {
  const _StatusSection({
    required this.current,
    required this.onPick,
    required this.onCustom,
  });

  final String current;
  final ValueChanged<String> onPick;
  final VoidCallback onCustom;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          '拨打情况',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black45),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final preset in statusPresets)
              ChoiceChip(
                label: Text(preset, style: const TextStyle(fontSize: 13)),
                selected: current == preset,
                selectedColor: const Color(0xFFE3ECFF),
                onSelected: (_) => onPick(preset),
              ),
            ActionChip(
              avatar: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('自定义填写', style: TextStyle(fontSize: 13)),
              onPressed: onCustom,
            ),
            if (current.isNotEmpty)
              ActionChip(
                avatar: const Icon(Icons.clear, size: 16),
                label: const Text('清空', style: TextStyle(fontSize: 13)),
                onPressed: () => onPick(''),
              ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          '结果写入表格末尾的「拨打情况」列，下次导入同名表格会自动带回来。',
          style: TextStyle(fontSize: 11, height: 1.4, color: Colors.black38),
        ),
      ],
    );
  }
}

class _NumberPickerSheet extends StatelessWidget {
  const _NumberPickerSheet({
    required this.title,
    required this.phones,
    required this.called,
  });

  final String title;
  final List<PhoneEntry> phones;
  final Set<String> called;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 12),
              itemCount: phones.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.black12),
              itemBuilder: (context, index) {
                final phone = phones[index];
                final dialed = phone.dialTarget != null && called.contains(phone.dialTarget);
                return ListTile(
                  enabled: phone.valid,
                  onTap: phone.valid ? () => Navigator.of(context).pop(phone) : null,
                  leading: CircleAvatar(
                    radius: 20,
                    backgroundColor: const Color(0xFFE7F7EE),
                    child: Icon(
                      _iconOf(phone.kind),
                      size: 20,
                      color: phone.valid ? const Color(0xFF17A05A) : Colors.black26,
                    ),
                  ),
                  title: Text(
                    phone.display,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: phone.valid ? theme.colorScheme.primary : Colors.black38,
                    ),
                  ),
                  subtitle: Text(
                    <String>[
                      PhoneUtils.kindLabel(phone.kind),
                      phone.label,
                      if (phone.note != null) phone.note!,
                      if (dialed) '已呼叫',
                    ].join(' · '),
                    style: const TextStyle(fontSize: 12, color: Colors.black45),
                  ),
                  trailing: const Icon(Icons.call, size: 20, color: Color(0xFF17A05A)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static IconData _iconOf(PhoneKind kind) {
    switch (kind) {
      case PhoneKind.mobile:
        return Icons.phone_iphone;
      case PhoneKind.service:
        return Icons.support_agent;
      case PhoneKind.landlineWithAreaCode:
      case PhoneKind.landlineLocal:
        return Icons.phone_in_talk_outlined;
      case PhoneKind.international:
        return Icons.public;
      case PhoneKind.unknown:
        return Icons.block;
    }
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.title, required this.message});

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 46, color: Colors.black26),
            const SizedBox(height: 12),
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.black45),
            ),
          ],
        ),
      ),
    );
  }
}