import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/sheet_data.dart';
import '../utils/phone_utils.dart';
import '../widgets/record_card.dart';

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

  /// 最近拨打的行（持续高亮，直到刷新列表 / 重新进入本页）
  int? _highlightRow;

  @override
  void initState() {
    super.initState();
    _called.addAll(widget.called);
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
    final sheet = widget.sheet;
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
    final sheet = widget.sheet;
    final fields = <CellField>[];
    for (var column = 0; column < sheet.columnCount; column++) {
      if (sheet.isPhoneColumn(column)) continue;
      final value = sheet.cellAt(row, column).trim();
      if (value.isEmpty) continue;
      fields.add(CellField(sheet.headerAt(column), value));
    }
    return fields;
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

  Future<void> _dialEntry(PhoneEntry entry, int row) async {
    final target = entry.dialTarget;
    if (target == null) {
      _toast('号码格式无法识别');
      return;
    }
    _markDialing(row);
    setState(() => _called.add(target));
    HapticFeedback.lightImpact();
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _copyAll() async {
    final sheet = widget.sheet;
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

  @override
  Widget build(BuildContext context) {
    final sheet = widget.sheet;
    final rows = _visibleRows();

    return Scaffold(
      appBar: AppBar(
        title: Text(sheet.name.isEmpty ? '号码列表' : sheet.name),
        actions: <Widget>[
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
              }
            },
            itemBuilder: (context) => const <PopupMenuEntry<String>>[
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
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: TextField(
              controller: _controller,
              onChanged: (value) => setState(() => _query = value),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索姓名 / 号码 / 其他字段',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _controller.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '共 ${sheet.rowCount} 条，当前显示 ${rows.length} 条',
                    style: const TextStyle(fontSize: 12, color: Colors.black45),
                  ),
                ),
                Text(
                  !sheet.hasPhoneColumn
                      ? '未选择号码列'
                      : sheet.phoneColumns.length == 1
                          ? '号码列：${sheet.headerAt(sheet.phoneColumn!)}'
                          : '号码列：${sheet.phoneColumns.map(sheet.headerAt).join(' / ')}',
                  style: const TextStyle(fontSize: 12, color: Colors.black45),
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
                    : ListView.builder(
                        padding: const EdgeInsets.only(top: 4, bottom: 24),
                        itemCount: rows.length,
                        itemBuilder: (context, index) {
                          final row = rows[index];
                          final fields = _fieldsOf(row);
                          final titleIndex = _titleIndexOf(fields);
                          final details = <CellField>[
                            for (var i = 0; i < fields.length; i++)
                              if (i != titleIndex) fields[i],
                          ];
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
                            onTap: () => _chooseAndDial(phones, row),
                            onPhoneTap: (entry) => _dialEntry(entry, row),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

/// 多号码时的拨号选择面板
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