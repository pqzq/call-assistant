import 'dart:typed_data';

import 'package:call_assistant/models/sheet_data.dart';
import 'package:call_assistant/services/excel_service.dart';
import 'package:call_assistant/utils/phone_utils.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _workbook() {
  final excel = Excel.createExcel();
  final sheet = excel['客户名单'];
  sheet.appendRow(<CellValue?>[
    TextCellValue('序号'),
    TextCellValue('姓名'),
    TextCellValue('部门'),
    TextCellValue('手机号码'),
    TextCellValue('备注'),
  ]);
  sheet.appendRow(<CellValue?>[
    IntCellValue(1),
    TextCellValue('张伟'),
    TextCellValue('销售一部'),
    TextCellValue('13800138000'),
    TextCellValue('首次咨询'),
  ]);
  sheet.appendRow(<CellValue?>[
    IntCellValue(2),
    TextCellValue('李静'),
    TextCellValue('销售二部'),
    TextCellValue('139 0013 9001'),
    TextCellValue('已发资料'),
  ]);
  // 号码被 Excel 存成数字（长号码会变成科学计数法）
  sheet.appendRow(<CellValue?>[
    IntCellValue(3),
    TextCellValue('王强'),
    TextCellValue('市场部'),
    DoubleCellValue(13700137002),
    TextCellValue('有意向'),
  ]);
  sheet.appendRow(<CellValue?>[
    IntCellValue(4),
    TextCellValue('赵敏'),
    TextCellValue('客服部'),
    TextCellValue('010-88886666'),
    TextCellValue(''),
  ]);
  // 尾部整行为空，应被丢弃
  sheet.appendRow(<CellValue?>[
    IntCellValue(5),
    TextCellValue('陈晨'),
    TextCellValue('技术部'),
    TextCellValue('+86 13500135004'),
    TextCellValue('转 123'),
  ]);
  return Uint8List.fromList(excel.encode() ?? const <int>[]);
}

void main() {
  group('ExcelService.parse', () {
    test('识别表头、数据行与手机号列', () {
      final sheets = ExcelService.parse(_workbook());
      expect(sheets.length, 1);

      final sheet = sheets.first;
      expect(sheet.name, '客户名单');
      expect(sheet.hasHeader, isTrue);
      expect(sheet.headerRow, 1);
      expect(sheet.headers, <String>['序号', '姓名', '部门', '手机号码', '备注']);
      expect(sheet.rowCount, 5);
      // 「手机号码」列（第 4 列）应被自动选中
      expect(sheet.phoneColumn, 3);
      expect(sheet.headerAt(sheet.phoneColumn!), '手机号码');
    });

    test('号码读取后可拨号（空格/数字/国际号/分机）', () {
      final sheet = ExcelService.parse(_workbook()).first;
      expect(sheet.rawPhoneAt(0), '13800138000');
      expect(sheet.rawPhoneAt(1), '139 0013 9001');
      expect(sheet.rawPhoneAt(2), '13700137002');
      expect(sheet.rawPhoneAt(3), '010-88886666');
      expect(sheet.rawPhoneAt(4), '+86 13500135004');
      expect(sheet.cellAt(0, 1), '张伟');
    });

    test('无表头时列名使用 A/B/C 自动编号', () {
      final excel = Excel.createExcel();
      final sheet = excel['原始数据'];
      sheet.appendRow(<CellValue?>[
        TextCellValue('张伟'),
        TextCellValue('13800138000'),
        TextCellValue('备注'),
      ]);
      sheet.appendRow(<CellValue?>[
        TextCellValue('李静'),
        TextCellValue('13900139001'),
        TextCellValue('已联系'),
      ]);

      final parsed = ExcelService.parse(
        Uint8List.fromList(excel.encode() ?? const <int>[]),
      ).first;

      expect(parsed.hasHeader, isFalse);
      expect(parsed.headers, <String>['A', 'B', 'C']);
      expect(parsed.rowCount, 2);
      expect(parsed.phoneColumn, 1);
    });

    test('空文件与非法内容抛出可读异常', () {
      expect(
        () => ExcelService.parse(Uint8List.fromList(const <int>[])),
        throwsA(isA<ExcelParseException>()),
      );
      expect(
        () => ExcelService.parse(Uint8List.fromList(<int>[1, 2, 3, 4, 5])),
        throwsA(isA<ExcelParseException>()),
      );
    });
  });

  test('示例数据：客户名单自动勾选手机号码 + 办公电话两列', () {
    final sheets = ExcelService.demoSheets();
    expect(sheets.length, 2);

    final mobile = sheets.first;
    expect(mobile.name, '客户名单');
    expect(mobile.phoneColumn, 3); // 主号码列仍是「手机号码」
    expect(mobile.phoneColumns, <int>[3, 4]); // 手机号码 + 办公电话
    expect(mobile.rowCount, 11);
    // 前三行是三大运营商客服号（公开服务电话，拨通不会有骚扰）
    expect(mobile.cellAt(0, 3), '10086');
    expect(mobile.cellAt(1, 3), '10010');
    expect(mobile.cellAt(2, 3), '10000');

    final landline = sheets[1];
    expect(landline.name, '固话名单');
    expect(landline.phoneColumns, <int>[2]);
    expect(landline.rowCount, 6);
  });

  group('ImportedSheet 多号码列', () {
    late ImportedSheet sheet;

    setUp(() {
      sheet = ExcelService.demoSheets().first;
    });

    test('phonesAt 按列顺序返回多个号码，座机补区号', () {
      // 第 1 行是运营商客服号（服务号）
      final phones = sheet.phonesAt(0, '021');
      expect(phones.length, 2);
      expect(phones[0].label, '手机号码');
      expect(phones[0].display, '10086');
      expect(phones[0].kind, PhoneKind.service);
      expect(phones[0].note, isNull);
      expect(phones[1].label, '办公电话');
      expect(phones[1].display, '010-88886666');
      expect(phones[1].note, isNull);

      // 「张伟」那行（第 4 行）是手机号
      final mobile = sheet.phonesAt(3, '021');
      expect(mobile[0].display, '13800138000');
      expect(mobile[0].kind, PhoneKind.mobile);

      // 「陈晨」那行（第 8 行）办公电话是本地座机，需补区号
      final local = sheet.phonesAt(7, '021');
      expect(local[1].display, '021-88886668');
      expect(local[1].note, '已补区号 021');
      expect(local[1].kind, PhoneKind.landlineLocal);
    });

    test('勾选/取消勾选列', () {
      final removed = sheet.togglePhoneColumn(4);
      expect(removed.phoneColumns, <int>[3]);

      final added = removed.togglePhoneColumn(1);
      expect(added.phoneColumns, <int>[3, 1]);

      final empty = added.togglePhoneColumn(3).togglePhoneColumn(1);
      expect(empty.phoneColumns, isEmpty);
      expect(empty.hasPhoneColumn, isFalse);
      expect(empty.phoneColumn, isNull);
    });

    test('忽略越界列', () {
      final updated = sheet.withPhoneColumns(<int>[3, 99, -1, 3]);
      expect(updated.phoneColumns, <int>[3]);
    });
  });
}