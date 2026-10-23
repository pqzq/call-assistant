import 'dart:convert';
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

/// Excel 导入 / 导出 + 手机号列自动识别
class ExcelService {
  const ExcelService._();

  /// 导出为 xlsx 二进制（表头 + 全部数据行，拨打情况在最后一列并已填充）
  static Uint8List exportToXlsx(ImportedSheet sheet) {
    final excel = Excel.createExcel();
    // 默认会有一张 Sheet1，先删掉，避免出现空表
    for (final name in excel.tables.keys.toList()) {
      excel.delete(name);
    }
    final target = excel[sheet.name.isEmpty ? '名单' : sheet.name];

    // 表头
    target.appendRow(<CellValue?>[
      for (final header in sheet.headers) TextCellValue(header),
    ]);

    // 数据行（含末尾的拨打情况列）
    for (var row = 0; row < sheet.rowCount; row++) {
      target.appendRow(<CellValue?>[
        for (var col = 0; col < sheet.columnCount; col++)
          TextCellValue(sheet.cellAt(row, col)),
      ]);
    }

    final bytes = excel.encode();
    return bytes == null ? Uint8List(0) : Uint8List.fromList(bytes);
  }

  /// 参与手机号列识别的最大数据行数
  static const int maxScanRows = 300;

  static List<ImportedSheet> parse(Uint8List bytes, {String? fileName}) {
    if (bytes.isEmpty) {
      throw const ExcelParseException('文件内容为空');
    }
    if (bytes.length > 80 * 1024 * 1024) {
      throw const ExcelParseException('文件过大（超过 80MB），请拆分后再导入');
    }

    // 1. 先按文本尝试（csv / tsv），很多「Excel 另存为」出来的其实是文本
    final csvSheets = _tryParseDelimited(bytes, fileName);
    if (csvSheets != null) return csvSheets;

    // 2. 按 Excel（xlsx / xls）解析
    final Excel excel;
    try {
      excel = Excel.decodeBytes(bytes);
    } catch (e) {
      // 把底层原因带出来，方便判断是格式问题还是文件损坏
      final reason = _shortReason(e);
      throw ExcelParseException(
        '无法解析该文件（$reason）。\n'
        '支持 .xlsx / .xls；若为 .csv 或 .txt，请确认是逗号/制表符分隔的纯文本，'
        '或先用 Excel 另存为「Excel 工作簿(*.xlsx)」再导入。',
      );
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

  /// 尝试按分隔文本（csv / tsv）解析；不是文本或没有可识别内容时返回 null
  static List<ImportedSheet>? _tryParseDelimited(Uint8List bytes, String? fileName) {
    // xlsx/xls 都是 zip 或二进制，不可能是可读文本
    if (bytes.length > 2 && bytes[0] == 0x50 && bytes[1] == 0x4B) return null; // PK.. (zip)
    if (bytes.length > 8 && bytes[0] == 0xD0 && bytes[1] == 0xCF) return null; // OLE (xls)

    String text;
    try {
      text = const Utf8Decoder(allowMalformed: true).convert(bytes);
    } catch (_) {
      return null;
    }
    // 必须包含可打印字符且有分隔符，否则不当作 csv
    final lines = const LineSplitter().convert(text);
    if (lines.isEmpty) return null;
    var printable = 0;
    for (final line in lines) {
      if (line.trim().isNotEmpty) printable++;
    }
    if (printable < 2) return null;

    final sample = lines.firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    final comma = sample.contains(',');
    final tab = sample.contains('\t');
    if (!comma && !tab) return null;

    final rows = <List<String>>[];
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      rows.add(_splitDelimited(line, tab && !comma ? '\t' : ','));
    }
    if (rows.isEmpty) return null;

    final name = (fileName == null || fileName.trim().isEmpty)
        ? '导入的表格'
        : fileName.replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '');
    return <ImportedSheet>[_buildSheet(name, rows)];
  }

  /// 解析一行分隔文本（支持双引号包裹与转义）
  static List<String> _splitDelimited(String line, String separator) {
    final cells = <String>[];
    final buffer = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            buffer.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          buffer.write(ch);
        }
      } else if (ch == '"') {
        inQuotes = true;
      } else if (ch == separator) {
        cells.add(buffer.toString().trim());
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }
    cells.add(buffer.toString().trim());
    return cells;
  }

  /// 提取底层异常里最有价值的一句
  static String _shortReason(Object error) {
    var text = error.toString().replaceAll('\n', ' ').trim();
    text = text.replaceFirst(RegExp(r'^(Exception|Invalid argument|FormatException)\s*:?\s*'), '');
    if (text.length > 80) text = '${text.substring(0, 80)}…';
    return text.isEmpty ? '格式无法识别' : text;
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

    // 末尾自动追加「拨打情况」列：拨完可在长按面板里直接标记结果
    return ImportedSheet(
      name: name,
      headers: headers,
      rows: dataRows,
      headerRow: hasHeader ? headerIndex + 1 : 0,
      phoneColumns: selected,
      phoneCandidates: candidates.where((c) => c.matched > 0).toList(),
      hasHeader: hasHeader,
    ).ensureStatusColumn();
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
      final byHeader = PhoneUtils.hasPhoneKeyword(header);
      var matched = 0; // 标准格式号码（手机/固话/国际）
      var serviceMatched = 0; // 5~6 位服务号（10086 等）
      var total = 0;
      for (final row in scan) {
        final value = c < row.length ? row[c].trim() : '';
        if (value.isEmpty) continue;
        total++;
        if (PhoneUtils.looksLikePhone(value)) {
          matched++;
        } else if (PhoneUtils.looksLikeServiceNumber(value)) {
          serviceMatched++;
        }
      }
      // 服务号只在「表头命中电话关键词 且 该列还有标准格式号码」时才采信，
      // 否则「编号 10001 / 10002」这类列会被误当成号码列
      final effectiveMatched = (byHeader && matched > 0) ? matched + serviceMatched : matched;
      candidates.add(PhoneCandidate(
        column: c,
        matched: effectiveMatched,
        total: total,
        byHeader: byHeader,
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
  ///
  /// 前几行放三大运营商的客服热线（10086/10010/10000）：这些号码是**公开服务电话**，
  /// 接通后是语音提示，既能完整跑通「接通 → 播报」链路，也不会打扰到真人。
  static List<ImportedSheet> demoSheets() {
    const mobileHeaders = <String>['序号', '姓名', '部门', '手机号码', '办公电话', '备注'];
    const mobileRows = <List<String>>[
      <String>['1', '中国移动客服', '客服热线', '10086', '010-88886666', '公开客服电话，接通为语音提示'],
      <String>['2', '中国联通客服', '客服热线', '10010', '010-88886667', '公开客服电话，接通为语音提示'],
      <String>['3', '中国电信客服', '客服热线', '10000', '010-88886668', '公开客服电话，接通为语音提示'],
      <String>['4', '张伟', '销售一部', '13800138000', '010-88886669', '首次咨询'],
      <String>['5', '李静', '销售二部', '13900139001', '010-88886670', '已发资料'],
      <String>['6', '王强', '市场部', '13700137002', '0571-88889999', '有意向'],
      <String>['7', '赵敏', '客服部', '13600136003', '', '待回访'],
      <String>['8', '陈晨', '技术部', '13500135004', '88886668', '转 123'],
      <String>['9', '刘洋', '销售一部', '18611118606', '88886669', '重点客户'],
      <String>['10', '孙丽', '人事部', '18922218907', '021-66668888', ''],
      <String>['11', '周杰', '技术部', '13433313408', '0755-88889900', '对接中'],
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
    ).ensureStatusColumn();
  }
}