import 'dart:convert';

import 'package:call_assistant/services/call_state_watcher.dart';
import 'package:call_assistant/services/lan_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LanMessage 编解码', () {
    test('answered 消息可往返编解码', () {
      final message = LanMessage(
        type: LanMessageType.answered,
        deviceId: 'abc123',
        deviceName: '拨号手机',
        role: 'dialer',
        script: '您好，我是本次项目的对接人',
        rowLabel: '张伟 13800138000',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

      final decoded = LanMessage.fromBytes(message.encode());

      expect(decoded, isNotNull);
      expect(decoded!.type, LanMessageType.answered);
      expect(decoded.deviceId, 'abc123');
      expect(decoded.deviceName, '拨号手机');
      expect(decoded.role, 'dialer');
      expect(decoded.script, '您好，我是本次项目的对接人');
      expect(decoded.rowLabel, '张伟 13800138000');
      expect(decoded.timestamp!.millisecondsSinceEpoch, 1700000000000);
    });

    test('hello 消息不含脚本时字段为空', () {
      final decoded = LanMessage.fromBytes(LanMessage(
        type: LanMessageType.hello,
        deviceId: 'dev1',
        deviceName: '播放手机',
        role: 'player',
      ).encode());

      expect(decoded!.type, LanMessageType.hello);
      expect(decoded.script, isEmpty);
      expect(decoded.rowLabel, isEmpty);
    });

    test('非法数据返回 null 而不抛异常', () {
      expect(LanMessage.fromBytes(utf8.encode('not json')), isNull);
      expect(LanMessage.fromBytes(utf8.encode('{"foo":1}')), isNull);
      expect(LanMessage.fromMap(null), isNull);
      expect(LanMessage.fromMap(<String, dynamic>{'type': 1, 'id': 'x'}), isNull);
    });
  });

  group('CallStateEvent 解析', () {
    test('接通事件带通话计时器', () {
      final event = CallStateEvent.fromMap(<String, dynamic>{
        'connected': true,
        'detail': '00:05',
        'package': 'com.android.incallui',
        'timestamp': 1700000000000,
      });

      expect(event, isNotNull);
      expect(event!.connected, isTrue);
      expect(event.duration, const Duration(seconds: 5));
      expect(event.packageName, 'com.android.incallui');
    });

    test('分钟级计时器', () {
      final event = CallStateEvent.fromMap(<String, dynamic>{
        'connected': true,
        'detail': '12:34',
        'timestamp': 1700000000000,
      });
      expect(event!.duration, const Duration(minutes: 12, seconds: 34));
    });

    test('只有文案没有计时器时 duration 为 null', () {
      final event = CallStateEvent.fromMap(<String, dynamic>{
        'connected': true,
        'detail': '通话中',
        'timestamp': 1700000000000,
      });
      expect(event!.connected, isTrue);
      expect(event.duration, isNull);
    });

    test('挂断事件与非法数据', () {
      final event = CallStateEvent.fromMap(<String, dynamic>{
        'connected': false,
        'detail': '通话结束',
      });
      expect(event!.connected, isFalse);
      expect(CallStateEvent.fromMap(<String, dynamic>{'detail': 'x'}), isNull);
      expect(CallStateEvent.fromMap('bad'), isNull);
    });
  });
}
