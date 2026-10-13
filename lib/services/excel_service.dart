import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../models/sheet_data.dart';
import '../utils/phone_utils.dart';

class ExcelParseException implements Exception {
  const ExcelParseException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Excel 导入 + 手机号列自动识别
class ExcelService {
  const ExcelService._();

  /// 参与手机号列识别的最大数据行数
  static const int maxScanRows = 300;

  static List<ImportedSheet> parse(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const ExcelParseException('文件内容为空');
    }
    if (bytes.length > 80 * 1024 * 1024) {
      throw const ExcelParseException('文件过大（超过 80MB），请拆分后再导入');
    }

    final Excel excel;
    try {
      excel = Excel.decodeBytes(bytes);
    } catch (_) {
      throw const ExcelParseException('无法解析该文件，请确认是 .xlsx 格式（xls / csv 请先另存为 .xlsx）');
    }

    final tables = excel.tables;
    final sheets = <ImportedSheet>[];
    for (final name in tables.keys) {
      final table = tables[name];
      if (table == null) continue;
      final rawRows = <List<String>>[];
      for (final row in table.rows) {
        rawRows.add([for (final cell in row) _cellText(cell)]);
      }
      sheets.add(_buildSheet(name, rawRows));
    }
    // 丢掉完全空白的工作表（例如 Excel 模板残留的空 Sheet）
    final nonEmpty = sheets.where((s) => s.rowCount > 0 || s.columnCount > 0).toList();
    if (nonEmpty.isEmpty) {
      throw const ExcelParseException('没有读取到表格数据，请确认文件内容不为空');
    }
    return nonEmpty;
  }

  static ImportedSheet _buildSheet(String name, List<List<String>> raw) {
    // 1. 去掉整行为空的行
    final rows = raw.where((row) => row.any((cell) => cell.trim().isNotEmpty)).toList();

    var width = 0;
    for (final row in rows) {
      if (row.length > width) width = row.length;
    }
    if (width == 0) {
      return ImportedSheet(
        name: name,
        headers: const <String>[],
        rows: const <List<String>>[],
        headerRow: 0,
        phoneColumns: const <int>[],
        phoneCandidates: const <PhoneCandidate>[],
        hasHeader: false,
      );
    }

    // 2. 每行去掉尾部空单元格并补齐宽度
    final normalized = <List<String>>[];
    for (final row in rows) {
      var end = row.length;
      while (end > 0 && row[end - 1].trim().isEmpty) {
        end--;
      }
      final cells = row.sublist(0, end);
      if (cells.length < width) {
        cells.addAll(List<String>.filled(width - cells.length, ''));
      }
      normalized.add(cells);
    }

    // 3. 猜测表头行
    final headerIndex = _findHeaderRow(normalized);
    final hasHeader = headerIndex >= 0;
    final headers = _buildHeaders(hasHeader ? normalized[headerIndex] : const <String>[], width);
    final dataRows = hasHeader ? normalized.sublist(headerIndex + 1) : normalized;

    // 4. 识别号码列（可能有多列，如 手机号码 + 办公电话）
    final candidates = _detectCandidates(headers, dataRows, width);
    final selected = <int>[
      for (final candidate in candidates)
        if (candidate.autoSelect) candidate.column,
    ];

    return ImportedSheet(
      name: name,
      headers: headers,
      rows: dataRows,
      headerRow: hasHeader ? headerIndex + 1 : 0,
      phoneColumns: selected,
      phoneCandidates: candidates.where((c) => c.matched > 0).toList(),
      hasHeader: hasHeader,
    );
  }

  /// 表头定位：先找带「手机/电话/姓名…」关键词的行，再退回第一个「不像数据」的行。
  static int _findHeaderRow(List<List<String>> rows) {
    final limit = rows.length < 10 ? rows.length : 10;
    for (var i = 0; i < limit; i++) {
      if (_hasKeywordCell(rows[i]) && _notDataLike(rows[i])) return i;
    }
    for (var i = 0; i < limit; i++) {
      if (_looksLikeHeader(rows[i])) return i;
    }
    return -1;
  }

  static bool _hasKeywordCell(List<String> row) {
    for (final cell in row) {
      if (PhoneUtils.hasPhoneKeyword(cell)) return true;
    }
    return false;
  }

  /// 号码占比低于 30% 才算「不像数据」。
  static bool _notDataLike(List<String> row) {
    final cells = row.where((cell) => cell.trim().isNotEmpty).toList();
    if (cells.isEmpty) return false;
    var phoneLike = 0;
    for (final cell in cells) {
      if (PhoneUtils.looksLikePhone(cell)) phoneLike++;
    }
    return phoneLike * 10 < cells.length * 3;
  }

  /// 表头判断：至少两个非空单元格，且不是以号码 / 纯数字为主。
  static bool _looksLikeHeader(List<String> row) {
    final cells = row.where((cell) => cell.trim().isNotEmpty).toList();
    if (cells.length < 2) return false;
    if (!_notDataLike(row)) return false;
    var numeric = 0;
    for (final cell in cells) {
      if (_numeric.hasMatch(cell.trim())) numeric++;
    }
    return numeric * 2 < cells.length;
  }

  static final RegExp _numeric = RegExp(r'^\d+(\.\d+)?$');

  static List<String> _buildHeaders(List<String> raw, int width) {
    final headers = <String>[];
    final used = <String, int>{};
    for (var c = 0; c < width; c++) {
      var name = c < raw.length ? raw[c].trim() : '';
      if (name.isEmpty) name = _columnLetter(c);
      final times = used[name] ?? 0;
      used[name] = times + 1;
      if (times > 0) name = '$name(${times + 1})';
      headers.add(name);
    }
    return headers;
  }

  static String _columnLetter(int index) {
    var n = index;
    final buffer = StringBuffer();
    while (n >= 0) {
      buffer.write(String.fromCharCode(65 + n % 26));
      n = n ~/ 26 - 1;
    }
    return buffer.toString();
  }

  static List<PhoneCandidate> _detectCandidates(
    List<String> headers,
    List<List<String>> rows,
    int width,
  ) {
    final scan = rows.length > maxScanRows ? rows.sublist(0, maxScanRows) : rows;
    final candidates = <PhoneCandidate>[];
    for (var c = 0; c < width; c++) {
      final header = c < headers.length ? headers[c] : '';
      var matched = 0;
      var total = 0;
      for (final row in scan) {
        final value = c < row.length ? row[c].trim() : '';
        if (value.isEmpty) continue;
        total++;
        if (PhoneUtils.looksLikePhone(value)) matched++;
      }
      candidates.add(PhoneCandidate(
        column: c,
        matched: matched,
        total: total,
        byHeader: PhoneUtils.hasPhoneKeyword(header),
      ));
    }
    candidates.sort((a, b) => b.score.compareTo(a.score));
    return candidates;
  }

  /// excel 2.x ~ 4.x 的单元格类型名不同（Cell / Data），这里用 dynamic 取值。
  static String _cellText(Object? cell) {
    if (cell == null) return '';
    try {
      return _valueText((cell as dynamic).value);
    } catch (_) {
      return '';
    }
  }

  static String _valueText(CellValue? value) {
    if (value == null) return '';
    if (value is TextCellValue) return value.toString().trim();
    if (value is IntCellValue) return value.value.toString();
    if (value is DoubleCellValue) return _formatDouble(value.value);
    if (value is BoolCellValue) return value.value ? 'TRUE' : 'FALSE';
    // 日期 / 时间 / 公式在不同版本字段名不同，统一用 toString()
    return value.toString().trim();
  }

  static String _formatDouble(double value) {
    if (value == value.roundToDouble() && value.abs() < 1e15) {
      return value.toStringAsFixed(0);
    }
    return value.toString();
  }

  /// 内置示例数据，方便在没有表格时先体验一遍。
  static List<ImportedSheet> demoSheets() {
    const mobileHeaders = <String>['序号', '姓名', '部门', '手机号码', '办公电话', '备注'];
    const mobileRows = <List<String>>[
      <String>['1', '张伟', '销售一部', '13800138000', '010-88886666', '首次咨询'],
      <String>['2', '李静', '销售二部', '13900139001', '010-88886667', '已发资料'],
      <String>['3', '王强', '市场部', '13700137002', '0571-88889999', '有意向'],
      <String>['4', '赵敏', '客服部', '13600136003', '', '待回访'],
      <String>['5', '陈晨', '技术部', '13500135004', '88886668', '转 123'],
      <String>['6', '刘洋', '销售一部', '18611118606', '88886669', '重点客户'],
      <String>['7', '孙丽', '人事部', '18922218907', '021-66668888', ''],
      <String>['8', '周杰', '技术部', '13433313408', '0755-88889900', '对接中'],
    ];
    const landlineHeaders = <String>['姓名', '部门', '办公座机', '备注'];
    const landlineRows = <List<String>>[
      <String>['张伟', '销售一部', '88886666', '本地座机，拨号自动补区号'],
      <String>['李静', '销售二部', '88886667', '同上'],
      <String>['王强', '市场部', '51234567', '7 位座机也支持'],
      <String>['赵敏', '客服部', '66668888', ''],
      <String>['孙丽', '人事部', '021-66668889', '已带区号，不会重复补'],
      <String>['周杰', '技术部', '0571-88889900', '外地座机保持原样'],
    ];

    return <ImportedSheet>[
      _buildDemoSheet('客户名单', mobileHeaders, mobileRows),
      _buildDemoSheet('固话名单', landlineHeaders, landlineRows),
    ];
  }

  static ImportedSheet _buildDemoSheet(String name, List<String> headers, List<List<String>> rows) {
    final data = rows.map((row) => row.toList()).toList();
    final candidates = _detectCandidates(headers, data, headers.length);
    final selected = <int>[
      for (final candidate in candidates)
        if (candidate.autoSelect) candidate.column,
    ];
    return ImportedSheet(
      name: name,
      headers: headers,
      rows: data,
      headerRow: 1,
      phoneColumns: selected,
      phoneCandidates: candidates.where((c) => c.matched > 0).toList(),
      hasHeader: true,
    );
  }
}