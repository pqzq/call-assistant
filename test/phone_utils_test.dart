import 'package:call_assistant/utils/phone_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PhoneUtils.normalize', () {
    test('普通手机号原样返回', () {
      expect(PhoneUtils.normalize('13800138000'), '13800138000');
    });

    test('去掉空格、横线、括号', () {
      expect(PhoneUtils.normalize('138 0013-8000'), '13800138000');
      expect(PhoneUtils.normalize('(010)8888-6666'), '01088886666');
    });

    test('保留国际区号', () {
      expect(PhoneUtils.normalize('+86 13800138000'), '+8613800138000');
    });

    test('小数形式与科学计数法', () {
      expect(PhoneUtils.normalize('13800138000.0'), '13800138000');
      expect(PhoneUtils.normalize('1.3800138E+10'), '13800138000');
    });

    test('带分机时只取主机号', () {
      expect(PhoneUtils.normalize('13500135004 转 123'), '13500135004');
    });

    test('非号码返回 null', () {
      expect(PhoneUtils.normalize('张三'), isNull);
      expect(PhoneUtils.normalize(''), isNull);
      expect(PhoneUtils.normalize(null), isNull);
    });
  });

  group('PhoneUtils.looksLikePhone', () {
    test('手机号、座机、国际号码', () {
      expect(PhoneUtils.looksLikePhone('13800138000'), isTrue);
      expect(PhoneUtils.looksLikePhone('010-88886666'), isTrue);
      expect(PhoneUtils.looksLikePhone('+8613800138000'), isTrue);
    });

    test('普通文本与短数字不算号码', () {
      expect(PhoneUtils.looksLikePhone('销售一部'), isFalse);
      expect(PhoneUtils.looksLikePhone('1'), isFalse);
      expect(PhoneUtils.looksLikePhone('2024'), isFalse);
    });

    test('运营商客服号（5~6 位）走独立判断，不混进普通号码规则', () {
      // 服务号和「编号 10001」长得一样，不能混进 looksLikePhone
      expect(PhoneUtils.looksLikePhone('10086'), isFalse);
      expect(PhoneUtils.looksLikeServiceNumber('10086'), isTrue);
      expect(PhoneUtils.looksLikeServiceNumber('10010'), isTrue);
      expect(PhoneUtils.looksLikeServiceNumber('10000'), isTrue);
      expect(PhoneUtils.looksLikeServiceNumber('12345'), isTrue);
      // 编号不该被当服务号
      expect(PhoneUtils.looksLikeServiceNumber('2024'), isFalse);
      expect(PhoneUtils.looksLikeServiceNumber('100'), isFalse);
      // 类型与可拨号码仍正常
      expect(PhoneUtils.kindOf('10086'), PhoneKind.service);
      expect(PhoneUtils.dialTarget('10086'), '10086');
    });
  });

  group('PhoneUtils.hasPhoneKeyword', () {
    test('命中手机/电话/phone 等关键词', () {
      expect(PhoneUtils.hasPhoneKeyword('手机号码'), isTrue);
      expect(PhoneUtils.hasPhoneKeyword('联系电话'), isTrue);
      expect(PhoneUtils.hasPhoneKeyword('Phone'), isTrue);
      expect(PhoneUtils.hasPhoneKeyword('姓名'), isFalse);
    });
  });

  group('PhoneUtils.kindOf', () {
    test('区分手机 / 固话 / 本地座机', () {
      expect(PhoneUtils.kindOf('13800138000'), PhoneKind.mobile);
      expect(PhoneUtils.kindOf('021-88886666'), PhoneKind.landlineWithAreaCode);
      expect(PhoneUtils.kindOf('88886666'), PhoneKind.landlineLocal);
      expect(PhoneUtils.kindOf('+8613800138000'), PhoneKind.international);
      expect(PhoneUtils.kindOf('张三'), PhoneKind.unknown);
    });

    test('needsAreaCode 只对本地座机为 true', () {
      expect(PhoneUtils.needsAreaCode('88886666'), isTrue);
      expect(PhoneUtils.needsAreaCode('51234567'), isTrue);
      expect(PhoneUtils.needsAreaCode('13800138000'), isFalse);
      expect(PhoneUtils.needsAreaCode('010-88886666'), isFalse);
    });
  });

  group('PhoneUtils.normalizeAreaCode', () {
    test('接受常见写法', () {
      expect(PhoneUtils.normalizeAreaCode('021'), '021');
      expect(PhoneUtils.normalizeAreaCode('21'), isNull, reason: '必须带前导 0');
      expect(PhoneUtils.normalizeAreaCode('0755'), '0755');
      expect(PhoneUtils.normalizeAreaCode(' 021 '), '021');
      expect(PhoneUtils.normalizeAreaCode('+86 021'), '021');
    });

    test('非法区号返回 null', () {
      expect(PhoneUtils.normalizeAreaCode('abc'), isNull);
      expect(PhoneUtils.normalizeAreaCode(''), isNull);
      expect(PhoneUtils.normalizeAreaCode('02100'), isNull);
    });
  });

  group('座机补区号', () {
    test('本地座机补默认区号 021', () {
      expect(PhoneUtils.dialTarget('88886666'), '02188886666');
      expect(PhoneUtils.dialTarget('8888-6666'), '02188886666');
    });

    test('可指定其它区号', () {
      expect(PhoneUtils.dialTarget('88886666', areaCode: '0755'), '075588886666');
      expect(PhoneUtils.dialTarget('88886666', areaCode: '0571'), '057188886666');
    });

    test('已带区号的座机不会重复补', () {
      expect(PhoneUtils.dialTarget('010-88886666'), '01088886666');
      expect(PhoneUtils.dialTarget('021-66668889', areaCode: '0755'), '02166668889');
    });

    test('手机号与国际号码不受区号影响', () {
      expect(PhoneUtils.dialTarget('13800138000', areaCode: '0755'), '13800138000');
      expect(PhoneUtils.dialTarget('+8613800138000', areaCode: '0755'), '+8613800138000');
    });

    test('区号非法时不返回号码', () {
      expect(PhoneUtils.dialTarget('88886666', areaCode: 'abc'), isNull);
    });
  });

  group('PhoneUtils.prettyDial', () {
    test('固话加横杠，手机号原样', () {
      expect(PhoneUtils.prettyDial('02188886666'), '021-88886666');
      expect(PhoneUtils.prettyDial('01088886666'), '010-88886666');
      expect(PhoneUtils.prettyDial('057188888888'), '0571-88888888');
      expect(PhoneUtils.prettyDial('13800138000'), '13800138000');
      expect(PhoneUtils.prettyDial('+8613800138000'), '+8613800138000');
    });
  });

  group('PhoneUtils.dialTarget', () {
    test('返回可拨号码', () {
      expect(PhoneUtils.dialTarget('138 0013 8000'), '13800138000');
      expect(PhoneUtils.dialTarget('+86 13800138000'), '+8613800138000');
    });

    test('无效号码返回 null', () {
      expect(PhoneUtils.dialTarget('暂无'), isNull);
    });
  });
}