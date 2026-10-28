import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// 开场白音频的局域网传输（TCP 单播）
///
/// 音频通常几百 KB 到几 MB，UDP 广播塞不下（单包 ~1.4KB），也做不到可靠传输。
/// 这里用一条**单播 TCP**：拨号端把文件挂在一个临时服务上，播放端连上去拉下来。
///
/// 只用于**已连接**的对端（单播需要对方的 IP）；任何环节失败都退回本地音频 / TTS，
/// 不影响播报本身。
class AudioTransfer {
  AudioTransfer._();

  /// TCP 端口：UDP 端口（47823）+ 1，避开局域网通道
  static const int defaultPort = 47824;

  /// 单文件上限（开场白 60 秒 wav 16k 单声道约 2MB，8MB 足够兜底）
  static const int maxBytes = 8 * 1024 * 1024;

  /// 连接 + 传输的整体超时
  static const Duration timeout = Duration(seconds: 8);

  static ServerSocket? _server;
  static bool _listening = false;

  /// 当前对外提供的文件（null = 没有可提供的音频）
  static File? _serving;

  /// 拨号端：设置要提供的音频文件，并确保服务已启动
  ///
  /// 传 null 表示当前没有音频（服务保留，下次直接换文件）。
  /// 返回 false 表示端口被占用 —— 音频传输不可用，但播报仍然走文本。
  static Future<bool> serve(File? file) async {
    _serving = file;
    if (file == null) return true;
    if (_listening) return true;
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, defaultPort);
      _listening = true;
    } catch (_) {
      return false;
    }
    _server!.listen(_onSocket, onError: (_) {});
    return true;
  }

  static void _onSocket(Socket socket) {
    final file = _serving;
    if (file == null || !file.existsSync()) {
      socket.destroy();
      return;
    }
    () async {
      try {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty || bytes.length > maxBytes) {
          socket.destroy();
          return;
        }
        // 协议：[4 字节大端长度][文件内容]，然后关闭
        final head = Uint8List(4);
        ByteData.view(head.buffer).setUint32(0, bytes.length, Endian.big);
        socket.add(head);
        socket.add(bytes);
        await socket.flush();
      } catch (_) {
        // 对方可能中途关闭，忽略
      } finally {
        try {
          await socket.close();
        } catch (_) {
          // 忽略
        }
      }
    }();
  }

  /// 播放端：从 [address] 拉取音频并写到 [target]
  ///
  /// 成功返回写入的文件；失败返回 null（调用方退回本地音频 / TTS）。
  static Future<File?> fetch(
    InternetAddress address,
    File target, {
    int port = defaultPort,
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(address, port, timeout: timeout);
      final chunks = <int>[];
      await for (final chunk in socket.timeout(timeout)) {
        chunks.addAll(chunk);
        if (chunks.length < 4) continue;
        final head = Uint8List.fromList(chunks.sublist(0, 4));
        final size = ByteData.view(head.buffer).getUint32(0, Endian.big);
        if (size <= 0 || size > maxBytes) return null;
        if (chunks.length < 4 + size) continue;
        await target.parent.create(recursive: true);
        await target.writeAsBytes(chunks.sublist(4, 4 + size), flush: true);
        return target;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      try {
        await socket?.close();
      } catch (_) {
        // 忽略
      }
    }
  }

  /// 停止对外服务（断开连接 / 关掉角色时）
  static Future<void> stop() async {
    _serving = null;
    if (!_listening) return;
    _listening = false;
    try {
      await _server?.close();
    } catch (_) {
      // 忽略
    }
    _server = null;
  }

  /// 当前是否正在对外提供音频（界面上可用于显示状态）
  static bool get serving => _serving != null && _listening;
}
