import 'package:call_assistant/services/dialer_service.dart';
import 'package:call_assistant/services/platform_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('平台能力（按目标平台）', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('Android：支持拨号跳转与通话检测', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(PlatformBridge.isAndroid, isTrue);
      expect(PlatformBridge.isDesktop, isFalse);
      expect(PlatformBridge.canDial, isTrue);
      expect(PlatformBridge.canDetectCall, isTrue);
      expect(DialerService.canDial, isTrue);
      expect(PlatformBridge.canDecodeAudio, isTrue);
    });

    test('Windows：桌面端，禁用拨号跳转与通话检测', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(PlatformBridge.isDesktop, isTrue);
      expect(PlatformBridge.isAndroid, isFalse);
      // 没有系统拨号能力 -> 点号码改为复制
      expect(PlatformBridge.canDial, isFalse);
      expect(DialerService.canDial, isFalse);
      // 无障碍只存在于 Android -> 不存在「拨号端」角色
      expect(PlatformBridge.canDetectCall, isFalse);
      // 音频解码（ASR）目前只有 Android 实现
      expect(PlatformBridge.canDecodeAudio, isFalse);
    });

    test('macOS / Linux 同样按桌面端处理', () {
      for (final platform in <TargetPlatform>[
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(PlatformBridge.isDesktop, isTrue, reason: '$platform 应视为桌面端');
        expect(PlatformBridge.canDial, isFalse);
        expect(PlatformBridge.canDetectCall, isFalse);
      }
    });
  });
}