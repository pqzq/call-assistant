import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Live2D 数字人资源管理：把打包进 assets 的 web 运行时与模型释放到磁盘，
/// 再用一个本地 HTTP 服务托管（file:// 下 WebView 的 fetch/model3.json 会被 CORS 拦住，
/// 用 127.0.0.1 服务最稳，也顺便支持用户自己导入的模型目录）。
class Live2dService {
  Live2dService._();

  static final Live2dService instance = Live2dService._();

  static const String _assetRoot = 'assets/live2d/';

  /// 资源版本：改了 assets 里的文件就 +1，启动时会重新释放
  static const String assetVersion = '4';

  static const String defaultModel = 'hiyori/Hiyori.model3.json';

  HttpServer? _server;
  Directory? _webRoot;
  String? _baseUrl;
  bool _preparing = false;

  bool get isRunning => _server != null;
  String? get baseUrl => _baseUrl;
  Directory? get webRoot => _webRoot;

  /// 准备资源目录 + 启动本地服务，返回 baseUrl
  Future<String?> ensureStarted() async {
    if (_baseUrl != null) return _baseUrl;
    if (_preparing) return null;
    _preparing = true;
    try {
      await _prepareWebRoot();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(_handle);
      _server = server;
      _baseUrl = 'http://127.0.0.1:${server.port}';
      return _baseUrl;
    } catch (_) {
      return null;
    } finally {
      _preparing = false;
    }
  }

  /// 可用模型列表（相对路径，如 hiyori/Hiyori.model3.json）
  Future<List<String>> listModels() async {
    final root = _webRoot;
    if (root == null) return const <String>[];
    final result = <String>[];
    for (final entity in root.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.model3.json')) {
        result.add(entity.path.substring(root.path.length + 1).replaceAll(r'\', '/'));
      }
    }
    result.sort();
    return result;
  }

  /// 导入用户自备的模型包（zip，内含 *.model3.json 及其依赖文件）
  /// 返回导入后的模型相对路径
  Future<String?> importModelArchive(File archiveFile, {String? name}) async {
    final root = _webRoot;
    if (root == null) return null;

    final bytes = await archiveFile.readAsBytes();
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      return null;
    }

    final files = archive.where((e) => e.isFile).toList();
    // 找到 model3.json，取它所在的目录作为模型根
    ArchiveFile? modelEntry;
    for (final entry in files) {
      if (entry.name.toLowerCase().endsWith('.model3.json')) {
        modelEntry = entry;
        break;
      }
    }
    if (modelEntry == null) return null;

    final modelPath = modelEntry.name.replaceAll('\\', '/');
    final cut = modelPath.lastIndexOf('/');
    final prefix = cut >= 0 ? modelPath.substring(0, cut + 1) : '';
    final dirName = (name ?? (cut >= 0 ? modelPath.substring(0, cut) : ''))
        .split('/')
        .where((e) => e.isNotEmpty)
        .lastOrNull ??
        'model';

    final targetDir = Directory('${root.path}/models/$dirName');
    if (targetDir.existsSync()) targetDir.deleteSync(recursive: true);
    targetDir.createSync(recursive: true);

    for (final entry in files) {
      final full = entry.name.replaceAll('\\', '/');
      if (prefix.isNotEmpty && !full.startsWith(prefix)) continue;
      final rel = prefix.isEmpty ? full : full.substring(prefix.length);
      if (rel.isEmpty) continue;
      final out = File('${targetDir.path}/$rel');
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(entry.content as List<int>);
    }

    return 'models/$dirName/${modelPath.substring(prefix.length)}';
  }

  /// 删除已导入的模型目录
  Future<void> deleteImportedModel(String modelRelativePath) async {
    final root = _webRoot;
    if (root == null) return;
    if (!modelRelativePath.startsWith('models/')) return;
    final name = modelRelativePath.split('/')[1];
    final dir = Directory('${root.path}/models/$name');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _baseUrl = null;
  }

  // ---------------- 内部实现 ----------------

  Future<void> _prepareWebRoot() async {
    if (_webRoot != null) return;

    Directory base;
    try {
      base = (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory();
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
    final root = Directory('${base.path}/live2d');
    if (!root.existsSync()) root.createSync(recursive: true);

    final marker = File('${root.path}/.asset_version');
    final upToDate = marker.existsSync() && marker.readAsStringSync().trim() == assetVersion;

    if (!upToDate) {
      await _extractAssets(root);
      marker.writeAsStringSync(assetVersion);
    }
    _webRoot = root;
  }

  Future<void> _extractAssets(Directory root) async {
    // 列出 assets/live2d/ 下所有文件（Flutter 运行时没法列目录，用 AssetManifest）
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final keys = manifest.listAssets().where((key) => key.startsWith(_assetRoot)).toList();

    for (final key in keys) {
      final relative = key.substring(_assetRoot.length);
      if (relative.isEmpty) continue;
      final data = await rootBundle.load(key);
      final out = File('${root.path}/$relative');
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final root = _webRoot;
    try {
      if (root == null) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }

      var path = Uri.decodeComponent(request.uri.path);
      if (path.endsWith('/') || path.isEmpty) path = '${path}index.html';
      if (path.contains('..')) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }

      final file = File('${root.path}$path');
      if (!file.existsSync()) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      request.response.headers.contentType = _contentTypeFor(path);
      request.response.headers.set('Cache-Control', 'no-store');
      await request.response.addStream(file.openRead());
      await request.response.close();
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {
        // 忽略
      }
    }
  }

  ContentType _contentTypeFor(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.html')) return ContentType.html;
    if (lower.endsWith('.js')) return ContentType('application', 'javascript', charset: 'utf-8');
    if (lower.endsWith('.json')) return ContentType('application', 'json', charset: 'utf-8');
    if (lower.endsWith('.png')) return ContentType('image', 'png');
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return ContentType('image', 'jpeg');
    if (lower.endsWith('.webp')) return ContentType('image', 'webp');
    return ContentType.binary;
  }
}

extension _LastOrNull<T> on Iterable<T> {
  T? get lastOrNull => isEmpty ? null : last;
}
