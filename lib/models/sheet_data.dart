import '../utils/phone_utils.dart';

/// 一行记录里某个号码列的具体信息
class PhoneEntry {
  const PhoneEntry({
    required this.column,
    required this.label,
    required this.raw,
    required this.dialTarget,
    required this.display,
    required this.kind,
    this.note,
  });

  /// 列索引
  final int column;

  /// 列名（表头）
  final String label;

  /// 表格里的原始文本
  final String raw;

  /// 可拨号码（本地座机已补区号），无法识别时为 null
  final String? dialTarget;

  /// 展示文本
  final String display;

  final PhoneKind kind;

  /// 提示，例如「已补区号 021」
  final String? note;

  bool get valid => dialTarget != null;
}

/// 导入后的单个工作表数据模型。
/// 拨打情况列的列名
const String statusColumnName = '拨打情况';

/// 拨打情况的快捷选项（最后一项「自定义」会弹输入框）
const List<String> statusPresets = <String>['拨打成功', '未接听', '已关机'];

class ImportedSheet {
  const ImportedSheet({
    required this.name,
    required this.headers,
    required this.rows,
    required this.headerRow,
    required this.phoneColumns,
    required this.phoneCandidates,
    required this.hasHeader,
    this.statusColumn,
  });

  /// 工作表名称
  final String name;

  /// 列名（无表头时自动生成 A、B、C...）
  final List<String> headers;

  /// 数据行（不含表头），每行列数与 headers 一致
  final List<List<String>> rows;

  /// 表头所在的行号（从 1 开始），0 表示没有表头
  final int headerRow;

  /// 选中的号码列（有序，第一个为主号码列），支持多选
  final List<int> phoneColumns;

  /// 自动识别出的候选号码列（按可信度降序）
  final List<PhoneCandidate> phoneCandidates;

  /// 是否存在表头行
  final bool hasHeader;

  /// 「拨打情况」列索引（null 表示还没加这一列）
  final int? statusColumn;

  /// 主号码列（兼容单列场景）
  int? get phoneColumn => phoneColumns.isEmpty ? null : phoneColumns.first;

  bool get hasPhoneColumn => phoneColumns.isNotEmpty;

  int get rowCount => rows.length;

  int get columnCount => headers.length;

  String headerAt(int column) =>
      column >= 0 && column < headers.length ? headers[column] : '第${column + 1}列';

  String cellAt(int row, int column) {
    if (row < 0 || row >= rows.length) return '';
    final cells = rows[row];
    return column >= 0 && column < cells.length ? cells[column] : '';
  }

  /// 该行指定列上的原始号码文本。
  String? rawPhoneAt(int row, {int? column}) {
    final target = column ?? phoneColumn;
    if (target == null) return null;
    final text = cellAt(row, target).trim();
    return text.isEmpty ? null : text;
  }

  bool isPhoneColumn(int column) => phoneColumns.contains(column);

  /// 该行所有选中号码列的号码，主列在前。
  List<PhoneEntry> phonesAt(int row, String areaCode) {
    final result = <PhoneEntry>[];
    for (final column in phoneColumns) {
      final raw = cellAt(row, column).trim();
      if (raw.isEmpty) continue;
      final target = PhoneUtils.dialTarget(raw, areaCode: areaCode);
      result.add(PhoneEntry(
        column: column,
        label: headerAt(column),
        raw: raw,
        dialTarget: target,
        display: target != null ? PhoneUtils.prettyDial(target) : raw,
        kind: PhoneUtils.kindOf(raw),
        note: PhoneUtils.needsAreaCode(raw) ? '已补区号 $areaCode' : null,
      ));
    }
    return result;
  }

  /// 是否有「拨打情况」列
  bool get hasStatusColumn => statusColumn != null;

  /// 读取某行的拨打情况（没有该列时返回空串）
  String statusAt(int row) {
    final column = statusColumn;
    if (column == null) return '';
    return cellAt(row, column);
  }

  /// 确保有「拨打情况」列：已有同名列就复用，没有才在末尾追加。
  ///
  /// 复用很重要：导出的 xlsx 里已经带这一列，再导入时不能重复追加，
  /// 否则会出现两列「拨打情况」，数据反而读不到。
  ImportedSheet ensureStatusColumn() {
    if (statusColumn != null) return this;
    final existing = headers.indexWhere((h) => h.trim() == statusColumnName);
    if (existing >= 0) {
      return copyWith(statusColumn: existing);
    }
    final newHeaders = <String>[...headers, statusColumnName];
    final newRows = <List<String>>[
      for (final row in rows) <String>[...row, ''],
    ];
    return copyWith(
      headers: newHeaders,
      rows: newRows,
      statusColumn: newHeaders.length - 1,
    );
  }

  /// 写入某行的拨打情况，返回新的 sheet（保持不可变，便于触发刷新）
  ImportedSheet withStatusAt(int row, String value) {
    final column = statusColumn;
    if (column == null || row < 0 || row >= rows.length) return this;
    final newRows = <List<String>>[
      for (var i = 0; i < rows.length; i++)
        if (i == row)
          <String>[
            for (var c = 0; c < columnCount; c++)
              if (c == column) value else cellAt(i, c),
          ]
        else
          rows[i],
    ];
    return copyWith(rows: newRows);
  }

  /// 复制并可选替换字段
  ImportedSheet copyWith({
    String? name,
    List<String>? headers,
    List<List<String>>? rows,
    int? headerRow,
    List<int>? phoneColumns,
    List<PhoneCandidate>? phoneCandidates,
    bool? hasHeader,
    int? statusColumn,
  }) {
    return ImportedSheet(
      name: name ?? this.name,
      headers: headers ?? this.headers,
      rows: rows ?? this.rows,
      headerRow: headerRow ?? this.headerRow,
      phoneColumns: phoneColumns ?? this.phoneColumns,
      phoneCandidates: phoneCandidates ?? this.phoneCandidates,
      hasHeader: hasHeader ?? this.hasHeader,
      statusColumn: statusColumn ?? this.statusColumn,
    );
  }

  /// 设置号码列（自动去重、过滤非法列）
  ImportedSheet withPhoneColumns(List<int> columns) {
    final valid = <int>[];
    for (final column in columns) {
      if (column >= 0 && column < columnCount && !valid.contains(column)) {
        valid.add(column);
      }
    }
    return copyWith(phoneColumns: valid);
  }

  /// 勾选/取消勾选某一列
  ImportedSheet togglePhoneColumn(int column) {
    final next = List<int>.of(phoneColumns);
    if (!next.remove(column)) {
      next.add(column);
    }
    return withPhoneColumns(next);
  }
}

/// 候选手机号列的识别结果。
class PhoneCandidate {
  const PhoneCandidate({
    required this.column,
    required this.matched,
    required this.total,
    required this.byHeader,
  });

  final int column;

  /// 命中号码格式的单元格数量
  final int matched;

  /// 非空单元格数量
  final int total;

  /// 表头是否包含「手机 / 电话 / phone」等关键词
  final bool byHeader;

  double get ratio => total == 0 ? 0 : matched / total;

  int get score => matched * 10 + (byHeader ? 100 : 0) + (total > 0 && matched == total ? 15 : 0);

  /// 是否达到自动勾选的门槛
  bool get autoSelect =>
      matched > 0 && ((byHeader && ratio >= 0.5) || (matched >= 2 && ratio >= 0.8));
}

/// 卡片上展示的「字段名 - 字段值」。
class CellField {
  const CellField(this.label, this.value);

  final String label;
  final String value;
}