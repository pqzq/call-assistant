import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 局域网消息类型
class LanMessageType {
  const LanMessageType._();

  /// 心跳/在线宣告（拨号端用它回应播放端的查询）
  static const String hello = 'hello';

  /// 播放端广播：寻找局域网里的拨号端
  static const String query = 'query';

  /// 播放端：请求与拨号端建立连接
  static const String connect = 'connect';

  /// 拨号端：已接受连接
  static const String connected = 'connected';

  /// 拨号端通知：对方已接通，请播放开场白
  static const String answered = 'answered';

  /// 拨号端通知：停止当前播报（打断）
  static const String stop = 'stop';

  /// 主动断开：任一方关掉角色 / 手动断开时广播，对端按 deviceId 匹配后清状态
  ///
  /// 用**广播**而不是单播：断开时对端可能 already 从 peers 列表过期，
  /// 拿不到 LanPeer 就没法单播。带上 deviceId 让对端自己判断。
  static const String bye = 'bye';

  /// 拨号端忙：已有播放端连着，拒绝新的连接请求
  static const String busy = 'busy';

  /// 拨号端 -> 播放端：我的开场白音频已挂到 TCP 服务上，你拉一下
  ///
  /// 只在**已连接**时响应用（消息里带 deviceId，播放端核对是不是自己那条连接）。
  static const String pushAudio = 'push_audio';

  /// 拨号端 -> 播放端：把我的开场白文本填到你那边
  static const String pushScript = 'push_script';
}

/// 局域网消息
class LanMessage {
  const LanMessage({
    required this.type,
    required this.deviceId,
    required this.deviceName,
    required this.role,
    this.script = '',
    this.rowLabel = '',
    this.timestamp,
  });

  final String type;

  /// 发送端设备 id（用于忽略自己发出的广播）
  final String deviceId;

  final String deviceName;

  /// dialer / player / both
  final String role;

  /// 要朗读的开场白文本
  final String script;

  /// 当前拨打的是谁（仅用于日志展示）
  final String rowLabel;

  final DateTime? timestamp;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'v': 1,
        'type': type,
        'id': deviceId,
        'name': deviceName,
        'role': role,
        'script': script,
        'row': rowLabel,
        'ts': (timestamp ?? DateTime.now()).millisecondsSinceEpoch,
      };

  /// 编码成待发送的字节
  List<int> encode() => utf8.encode(jsonEncode(toMap()));

  static LanMessage? fromBytes(List<int> bytes) {
    try {
      return fromMap(jsonDecode(utf8.decode(bytes)));
    } catch (_) {
      return null;
    }
  }

  static LanMessage? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final type = raw['type'];
    final id = raw['id'];
    if (type is! String || id is! String) return null;
    final ts = raw['ts'];
    return LanMessage(
      type: type,
      deviceId: id,
      deviceName: (raw['name'] as String?) ?? '',
      role: (raw['role'] as String?) ?? '',
      script: (raw['script'] as String?) ?? '',
      rowLabel: (raw['row'] as String?) ?? '',
      timestamp: ts is int ? DateTime.fromMillisecondsSinceEpoch(ts) : null,
    );
  }
}

/// 局域网对端设备
class LanPeer {
  LanPeer({
    required this.deviceId,
    required this.deviceName,
    required this.role,
    required this.address,
    required this.lastSeen,
  });

  final String deviceId;
  final String deviceName;
  final String role;
  final InternetAddress address;
  DateTime lastSeen;

  String get displayName => deviceName.isEmpty ? deviceId : deviceName;
}

/// 基于 UDP 广播的局域网通道：无需知道对端 IP，同网段即可互通
class LanLink {
  LanLink({this.port = defaultPort});

  /// 固定端口，两端一致
  static const int defaultPort = 47823;

  final int port;

  /// 本机设备 id：广播会回环到自己，需要过滤掉
  String? localDeviceId;

  /// 单机自测：允许把自己发出的广播也交给上层处理（模拟对端）


  RawDatagramSocket? _socket;
  final Map<String, LanPeer> _peers = <String, LanPeer>{};

  bool get isRunning => _socket != null;

  /// 当前在线（15 秒内有心跳）的对端
  List<LanPeer> get peers {
    final now = DateTime.now();
    return _peers.values.where((p) => now.difference(p.lastSeen).inSeconds < 15).toList();
  }

  Future<bool> start(void Function(LanMessage message, LanPeer peer) onMessage) async {
    if (_socket != null) return true;
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);
      socket.broadcastEnabled = true;
      socket.listen((RawSocketEvent event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        final message = LanMessage.fromBytes(datagram.data);
        if (message == null) return;
        // 忽略自己发出的广播（UDP 广播会回环给发送方，否则会把自己当成对端）
        // 单机自测模式下要保留，用来模拟"另一台手机"
        if (localDeviceId != null && message.deviceId == localDeviceId) return;
        final peer = LanPeer(
          deviceId: message.deviceId,
          deviceName: message.deviceName,
          role: message.role,
          address: datagram.address,
          lastSeen: DateTime.now(),
        );
        _peers[message.deviceId] = peer;
        onMessage(message, peer);
      }, onError: (Object _) {
        // 手机只有移动数据时广播会失败（Operation not permitted），
        // 这里吞掉错误，避免未捕获异常刷屏/打断心跳
      });
      _socket = socket;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 广播（同时向已发现的对端单播，避免路由器屏蔽 255.255.255.255）
  void broadcast(LanMessage message) {
    final socket = _socket;
    if (socket == null) return;
    final data = message.encode();
    try {
      socket.send(data, InternetAddress('255.255.255.255'), port);
    } catch (_) {
      // 忽略
    }
    for (final peer in peers) {
      try {
        socket.send(data, peer.address, port);
      } catch (_) {
        // 忽略
      }
    }
  }

  /// 单播给指定对端（连接握手用，避免广播被其它设备看到）
  void sendTo(LanMessage message, LanPeer peer) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.send(message.encode(), peer.address, port);
    } catch (_) {
      // 忽略
    }
  }

  void close() {
    _socket?.close();
    _socket = null;
    _peers.clear();
  }
}
