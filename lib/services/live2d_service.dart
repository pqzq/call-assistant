import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_paths.dart';

/// Live2D 数字人资源管理：把打包进 assets 的 web 运行时与模型释放到磁盘，
/// 再用一个本地 HTTP 服务托管（file:// 下 WebView 的 fetch/model3.json 会被 CORS 拦住，
/// 用 127.0.0.1 服务最稳，也顺便支持用户自己导入的模型目录）。
class Live2dService {
  Live2dService._();

  static final Live2dService instance = Live2dService._();

  static const String _assetRoot = 'assets/live2d/';

  /// 资源版本：改了 assets 里的文件就 +1，启动时会重新释放
  static const String assetVersion = '13';

  /// 计算资源版本号：基础版本 + index.html 内容哈希
  ///
  /// 放进 WebView 的 URL（`v=` 参数）可以顺带**破掉 WebView 缓存** ——
  /// WebView 会缓存 index.html，资源更新后 URL 不变就会一直加载旧页面。
  static Future<String> computeAssetVersion() async {
    final base = assetVersion;
    try {
      final data = await rootBundle.load('assets/live2d/index.html');
      var hash = 0;
      for (final b in data.buffer.asUint8List()) {
        hash = (hash * 31 + b) & 0x7fffffff;
      }
      return '$base.${hash.toRadixString(16)}';
    } catch (_) {
      return base;
    }
  }

  static const String defaultModel = 'hiyori/Hiyori.model3.json';

  HttpServer? _server;
  Directory? _webRoot;
  String? _baseUrl;
  /// 正在进行的启动流程（并发调用共享，避免第二个调用直接拿到 null）
  Future<String?>? _preparingFuture;

  bool get isRunning => _server != null;
  String? get baseUrl => _baseUrl;
  Directory? get webRoot => _webRoot;

  /// 准备资源目录 + 启动本地服务，返回 baseUrl
  Future<String?> ensureStarted() {
    if (_baseUrl != null) return Future<String?>.value(_baseUrl);
    return _preparingFuture ??= _startService();
  }

  /// 只准备资源目录（释放 assets + 保留用户导入的模型），**不启动 HttpServer**
  ///
  /// 原生渲染后端（Cubism Native SDK）直接读磁盘文件，不需要本地 HTTP 服务。
  Future<Directory?> ensureWebRoot() async {
    if (_webRoot != null) return _webRoot;
    try {
      await _prepareWebRoot();
    } catch (e) {
      // ignore: avoid_print
      print('[Live2D] 准备资源目录失败: $e');
      return null;
    }
    return _webRoot;
  }

  Future<String?> _startService() async {
    try {
      await _prepareWebRoot();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(_handle);
      _server = server;
      _baseUrl = 'http://127.0.0.1:${server.port}';
      return _baseUrl;
    } catch (e) {
      // ignore: avoid_print
      print('[Live2D] 本地服务启动失败: $e');
      return null;
    } finally {
      _preparingFuture = null;
    }
  }

  /// 模型描述文件的标准后缀（Cubism 3/4/5 都用它）
  static const String modelFileSuffix = '.model3.json';

  /// 判断一个文件是不是 Live2D 模型描述文件。
  ///
  /// 优先按**后缀**判断（`*.model3.json`，大小写不敏感）；
  /// 后缀不标准时（比如被改名成 model.json / config.json）再按**内容**兜底：
  /// 含有 `FileReferences` 且引用了 `Moc` 即认为是模型描述文件。
  static bool isModelDescriptionFile(String name, {String? content}) {
    final lower = name.split('/').last.toLowerCase();
    // 后缀判断：xxx.model3.json 或 model3.json 都算（大小写不敏感）
    if (lower.endsWith('model3.json')) return true;
    if (!lower.endsWith('.json')) return false;
    if (content == null) return false;
    return content.contains('"FileReferences"') && content.contains('"Moc"');
  }

  /// 从模型文件路径里取出展示名（去掉 .model3.json 后缀）
  static String modelNameOf(String path) {
    final file = path.split('/').last;
    final lower = file.toLowerCase();
    if (lower.endsWith(modelFileSuffix)) {
      return file.substring(0, file.length - modelFileSuffix.length);
    }
    if (lower == 'model3.json') {
      final dir = path.split('/');
      return dir.length > 1 ? dir[dir.length - 2] : file;
    }
    final dot = file.lastIndexOf('.');
    return dot > 0 ? file.substring(0, dot) : file;
  }

  /// 可用模型列表（相对路径，如 hiyori/Hiyori.model3.json）
  /// 只返回 Cubism 4/5 的模型；Cubism 3（moc3 v6）当前运行时不支持
  Future<List<String>> listModels() async {
    final root = _webRoot;
    if (root == null) return const <String>[];
    final result = <String>[];
    // 只递归遍历**目录**、只挑 .model3.json：
    // 直接 listSync(recursive: true) 会把上千张贴图也列一遍，很慢，
    // 表现出来就是点「切换模型」之后半天没反应。
    final modelFiles = <File>[];
    void scan(Directory dir, int depth) {
      if (depth > 8) return;
      List<FileSystemEntity> children;
      try {
        children = dir.listSync(followLinks: true);
      } catch (_) {
        return;
      }
      for (final entity in children) {
        if (entity is File) {
          if (entity.path.toLowerCase().endsWith('.model3.json')) modelFiles.add(entity);
        } else if (entity is Directory) {
          scan(entity, depth + 1);
        }
      }
    }

    scan(root, 0);

    for (final entity in modelFiles) {
      final relative = entity.path.substring(root.path.length + 1).replaceAll(r'\', '/');
      if (await isSupportedModel(entity)) {
        result.add(relative);
      } else {
        incompatibleModels.add(relative);
      }
    }
    // 桌面端：内置模型没有复制到 userdata（直接从 app 资源目录读），
    // 这里把 app 自带的那份也扫进模型列表。
    final builtIn = builtInLive2dDir;
    if (builtIn != null) {
      final builtInFiles = <File>[];
      void walk(Directory dir, int depth) {
        if (depth > 8) return;
        List<FileSystemEntity> children;
        try {
          children = dir.listSync(followLinks: true);
        } catch (_) {
          return;
        }
        for (final e in children) {
          if (e is File) {
            if (e.path.toLowerCase().endsWith('.model3.json')) builtInFiles.add(e);
          } else if (e is Directory) {
            walk(e, depth + 1);
          }
        }
      }
      walk(builtIn, 0);
      for (final entity in builtInFiles) {
        final relative = entity.path
            .substring(builtIn.path.length + 1)
            .replaceAll(r'\\', '/');
        if (await isSupportedModel(entity)) {
          result.add(relative);
        } else {
          incompatibleModels.add(relative);
        }
      }
    }
    // 两个目录可能扫到同名模型（userdata 里的旧副本没删掉时），去重
    final deduped = result.toSet().toList();
    deduped.sort();
    return deduped;
  }

  /// 被排除的 Cubism 3 模型（供界面提示）
  final List<String> incompatibleModels = <String>[];

  /// 内置模型都放在资源根目录下（hiyori/ haru/ ...），
  /// 用户自己导入的模型统一放在 `models/` 下 —— 用它区分两者，
  /// 内置模型不允许被移除。
  static bool isUserImported(String modelRelativePath) =>
      modelRelativePath.startsWith('models/');

  /// 判断模型是否为当前运行时支持的 Cubism 4/5
  ///
  /// 注意：model3.json 里的 `Version` 是**模型描述格式版本**（Cubism 4 也是 3），
  /// 不能用来判断 SDK 版本；真正的判据是 moc3 文件头的版本号：
  /// Cubism 3 的 moc3 是 v6，Cubism 4/5 的 moc3 是 v5 及以下（Cubism 5 Core 只支持到 v5）。
  Future<bool> isSupportedModel(File modelFile) async {
    try {
      final raw = await modelFile.readAsString();
      final json = jsonDecode(raw);
      if (json is! Map) return true;
      final refs = json['FileReferences'];
      if (refs is! Map) return true;
      final moc = refs['Moc'];
      if (moc is! String || moc.isEmpty) return true;
      final mocFile = File(
        '${modelFile.parent.path}${Platform.pathSeparator}${moc.replaceAll('/', Platform.pathSeparator)}',
      );
      if (!mocFile.existsSync()) return true;
      final handle = await mocFile.open();
      try {
        final header = await handle.read(6);
        if (header.length < 6) return true;
        final magic = String.fromCharCodes(header.sublist(0, 4));
        final version = header[4] | (header[5] << 8);
        if (magic != 'MOC3') return true;
        // v6 = Cubism 3，当前运行时不支持
        return version <= 5;
      } finally {
        await handle.close();
      }
    } catch (_) {
      return true; // 解析失败时先放过，交给运行时报错
    }
  }

  /// 导入用户自备的模型包（zip，内含模型描述文件及其依赖文件）
  /// 返回导入后的模型相对路径
  Future<String?> importModelArchive(File archiveFile, {String? name}) async {
    // 同上：先确保资源目录已初始化
    await ensureStarted();
    final root = _webRoot;
    if (root == null) {
      lastImportError = '本地资源目录未初始化，请先开启一次数字人';
      return null;
    }

    final bytes = await archiveFile.readAsBytes();
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      return null;
    }

    final files = archive.where((e) => e.isFile).toList();
    // 找模型描述文件：先按后缀（*.model3.json），再按内容兜底（改过名的 json）
    ArchiveFile? modelEntry;
    for (final entry in files) {
      if (isModelDescriptionFile(entry.name)) {
        modelEntry = entry;
        break;
      }
    }
    if (modelEntry == null) {
      // 后缀不标准时，按内容再找一遍
      for (final entry in files) {
        if (!entry.name.toLowerCase().endsWith('.json')) continue;
        try {
          final content = utf8.decode(entry.content as List<int>, allowMalformed: true);
          if (isModelDescriptionFile(entry.name, content: content)) {
            modelEntry = entry;
            break;
          }
        } catch (_) {
          // 忽略
        }
      }
    }
    if (modelEntry == null) return null;

    final modelPath = modelEntry.name.replaceAll('\\', '/');
    final cut = modelPath.lastIndexOf('/');
    final prefix = cut >= 0 ? modelPath.substring(0, cut + 1) : '';
    final dirName = (name ?? modelNameOf(modelPath))
        .replaceAll(RegExp(r'[^\w\-.\u4e00-\u9fa5]'), '_')
        .trim();
    final safeName = dirName.isEmpty ? 'model' : dirName;

    final targetDir = Directory('${root.path}/models/$safeName');
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

    return 'models/$safeName/${modelPath.substring(prefix.length)}';
  }

  /// 最近一次导入失败的原因（供界面提示，避免一律报「没有找到 .model3.json」）
  String? lastImportError;

  /// 把 SAF 返回的路径转成真实的文件系统路径。
  ///
  /// 文件选择器返回的可能是：
  /// - `/document/primary:Download`（DocumentsUI 的 documentId 形式）
  /// - `content://com.android.externalstorage.documents/primary%3ADownload`
  /// - `primary:Download`
  /// 这些都不是 dart:io 能用的路径，需要映射到 `/storage/emulated/0/...`。
  static String resolveRealPath(String raw) {
    var path = raw.trim();
    // content:// URI -> documentId
    final docMatch = RegExp(r'/document/(.+)$').firstMatch(path);
    if (docMatch != null) {
      path = Uri.decodeComponent(docMatch.group(1)!);
    } else if (path.startsWith('content://')) {
      // 兜底：取最后一个 / 后面的部分
      final tail = path.split('/').last;
      path = Uri.decodeComponent(tail);
    }
    // documentId 形如 primary:Download 或 XXXX-XXXX:Download
    if (path.contains(':')) {
      final parts = path.split(':');
      final volume = parts.first;
      final rest = parts.length > 1 ? parts.sublist(1).join(':') : '';
      if (volume == 'primary') {
        return '/storage/emulated/0/$rest';
      }
      return '/storage/$volume/$rest';
    }
    return path;
  }

  /// 用 shell 列目录（dart:io 在部分 ROM 上会被分区存储拦掉，shell 更宽松）
  static List<String> _tryListViaShell(String path) {
    try {
      final result = Process.runSync('ls', <String>['-1', path]);
      if (result.exitCode != 0) return const <String>[];
      final out = (result.stdout as String).trim();
      if (out.isEmpty) return const <String>[];
      return out.split('\n');
    } catch (_) {
      return const <String>[];
    }
  }

  /// 从文件夹导入模型：递归寻找 *.model3.json，并把该模型目录（含贴图/动作/表情）
  /// 整体复制到 models/ 下。返回导入后的模型相对路径。
  Future<String?> importModelFolder(Directory folder, {String? name}) async {
    // 先确保资源目录已初始化：没开过数字人时 _webRoot 还是空的，
    // 否则会在检查文件之前就直接返回，表现为「明明有 model3.json 却提示不存在」
    await ensureStarted();
    final root = _webRoot;
    if (root == null) {
      lastImportError = '本地资源目录未初始化，请先开启一次数字人';
      return null;
    }
    lastImportError = null;
    // SAF 返回的可能是 documentId 形式，需要转成真实路径
    final realPath = resolveRealPath(folder.path);
    debugPrint('[Live2D] 导入目录: 原始=${folder.path} 转换后=$realPath');
    if (realPath != folder.path) {
      folder = Directory(realPath);
    }
    if (!folder.existsSync()) {
      // 目录「存在但列不出来」是分区存储下的典型表现：existsSync 通过，
      // 但 listSync 会抛权限错误。这里用 shell 再确认一次。
      final listed = _tryListViaShell(folder.path);
      if (listed.isEmpty) {
        lastImportError = '无法访问该目录（路径：${folder.path}）';
        return null;
      }
      lastImportError = '目录不存在或无法访问';
      return null;
    }

    // 递归查找模型描述文件：先按后缀（*.model3.json），再按内容兜底
    final models = <File>[];
    final jsonCandidates = <File>[];
    var unreadable = 0;
    void scan(Directory dir, int depth) {
      if (depth > 8 || models.length > 20) return;
      List<FileSystemEntity> children;
      try {
        // followLinks: true —— 部分解压工具会建符号链接，false 会直接漏掉
        children = dir.listSync(followLinks: true);
      } catch (_) {
        unreadable++;
        return;
      }
      for (final entity in children) {
        if (entity is File) {
          if (isModelDescriptionFile(entity.path)) {
            models.add(entity);
          } else if (entity.path.toLowerCase().endsWith('.json')) {
            jsonCandidates.add(entity);
          }
        }
      }
      for (final entity in children) {
        if (entity is Directory) {
          final name = entity.path.split(Platform.pathSeparator).last;
          if (name.startsWith('.') || name == '__MACOSX') continue;
          scan(entity, depth + 1);
        }
      }
    }

    scan(folder, 0);
    if (models.isEmpty) {
      // 兜底：一次性递归遍历（某些目录下 listSync 逐层列举会失败）
      try {
        for (final entity in folder.listSync(recursive: true, followLinks: true)) {
          if (entity is File && isModelDescriptionFile(entity.path)) {
            models.add(entity);
          }
        }
      } catch (_) {
        // 忽略
      }
    }
    if (models.isEmpty) {
      // 后缀不标准（模型 json 被改过名）时按内容再找一遍
      for (final candidate in jsonCandidates) {
        try {
          final content = await candidate.readAsString();
          if (isModelDescriptionFile(candidate.path, content: content)) {
            models.add(candidate);
            break;
          }
        } catch (_) {
          // 忽略
        }
      }
    }
    if (models.isEmpty) {
      // 给出能定位问题的原因，而不是笼统的「没有找到」
      if (unreadable > 0) {
        lastImportError = '无法读取该目录（Android 11+ 需要「所有文件访问权限」），'
            '建议改用「导入模型包（zip）」';
      } else if (jsonCandidates.isNotEmpty) {
        lastImportError = '目录里有 ${jsonCandidates.length} 个 json，但都不是模型描述文件'
            '（需要 *.model3.json）';
      } else {
        lastImportError = '该目录里没有找到 .model3.json（路径：${folder.path}）';
      }
      return null;
    }
    models.sort((a, b) => a.path.length.compareTo(b.path.length));
    final modelFile = models.first;

    // 模型根目录 = model3.json 所在目录
    final modelDir = modelFile.parent;
    final dirName = (name ?? modelDir.path.split(Platform.pathSeparator).last)
        .replaceAll(RegExp(r'[^\w\-. 一-龥]'), '_')
        .trim();
    final safeName = dirName.isEmpty ? 'model' : dirName;

    final targetDir = Directory('${root.path}/models/$safeName');
    if (targetDir.existsSync()) targetDir.deleteSync(recursive: true);
    targetDir.createSync(recursive: true);

    // 复制整个模型目录（相对 model3.json 的引用都在其中）
    var copied = 0;
    void copyTree(Directory from, Directory to) {
      for (final entity in from.listSync(followLinks: false)) {
        final baseName = entity.path.split(Platform.pathSeparator).last;
        if (entity is File) {
          final target = File('${to.path}/$baseName');
          try {
            target.writeAsBytesSync(entity.readAsBytesSync());
            copied++;
          } catch (_) {
            // 跳过读不了的文件
          }
        } else if (entity is Directory) {
          if (baseName.startsWith('.') || baseName == '__MACOSX') continue;
          final target = Directory('${to.path}/$baseName');
          target.createSync(recursive: true);
          copyTree(entity, target);
        }
      }
    }

    copyTree(modelDir, targetDir);
    if (copied == 0) return null;

    final relativeModel = 'models/$safeName/${modelFile.path.split(Platform.pathSeparator).last}';
    return relativeModel;
  }

  /// 删除已导入的模型目录（只允许删用户导入的，内置模型会被忽略）
  Future<void> deleteImportedModel(String modelRelativePath) async {
    final root = _webRoot;
    if (root == null) return;
    if (!isUserImported(modelRelativePath)) return;
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

  /// 桌面端 app 自带的 live2d 资源目录（磁盘上的**真实路径**）
  ///
  /// Windows / Linux / macOS 的 Flutter asset 是**实体文件**，就放在
  /// 可执行文件旁边的 flutter_assets 里，可以直接按路径读取 ——
  /// 不需要再复制一份到 userdata（那样会白白多占一份，内置模型约 20MB）。
  ///
  /// Android 返回 null：apk 里的 asset 没有文件路径，必须复制出来。
  static Directory? get builtInLive2dDir {
    if (Platform.isAndroid) return null;
    final sep = Platform.pathSeparator;
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      // Windows / Linux 的 release 布局
      final win = Directory(
          '${exeDir.path}${sep}data${sep}flutter_assets${sep}assets${sep}live2d');
      if (win.existsSync()) return win;
      // macOS：Contents/MacOS/app -> .../Resources/flutter_assets
      final mac = Directory(
          '${exeDir.path}$sep..${sep}Frameworks${sep}App.framework${sep}Versions${sep}A${sep}Resources${sep}flutter_assets${sep}assets${sep}live2d');
      if (mac.existsSync()) return mac;
    } catch (_) {
      // 拿不到就返回 null，走「复制」的兜底路径
    }
    return null;
  }

  /// 解析模型的**目录**：先找 userdata，再回退到 app 自带资源
  ///
  /// ⚠️ 光给 HTTP 服务加回退是不够的：**Windows 原生渲染后端不走 HTTP**，
  /// 它把模型目录路径直接交给插件按文件加载（贴图 / moc3 都由插件读）。
  /// 内置模型现在不在 userdata 里，所以这条路径也必须走同一套回退逻辑，
  /// 否则表现就是「Windows 加载不到默认模型」。
  static String resolveModelDir(String rootPath, String relativePath) {
    final sep = Platform.pathSeparator;
    final normalized = relativePath.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    if (slash <= 0) return rootPath;
    final sub = normalized.substring(0, slash).replaceAll('/', sep);

    final inUserData = '$rootPath$sep$sub';
    if (Directory(inUserData).existsSync()) return inUserData;

    final builtIn = builtInLive2dDir;
    if (builtIn != null) {
      final inApp = '${builtIn.path}$sep$sub';
      if (Directory(inApp).existsSync()) return inApp;
    }
    // 两边都没有就返回原来的路径，让上层按原样报错
    return inUserData;
  }

  Future<void> _prepareWebRoot() async {
    if (_webRoot != null) return;

    // 统一数据根目录（AppPaths，Windows 为 exe 同级 userdata）下的 live2d 子目录
    final root = AppPaths.live2dDir;
    // ignore: avoid_print
    print('[Live2D] 资源目录: ${root.path}');
    if (!root.existsSync()) root.createSync(recursive: true);

    final builtIn = builtInLive2dDir;
    if (builtIn != null) {
      // 桌面端（Windows / Linux / macOS）：asset 本身就是实体文件，
      // **直接引用，不复制** —— userdata/live2d 只用来放用户导入的模型。
      // 省掉一整份内置资源（约 20MB）的重复占用。
      if (!root.existsSync()) {
        root.createSync(recursive: true);
      } else {
        // 旧版本已经复制过一份，这里回收掉（只保留用户导入的 models/）
        _removeCopiedBuiltInAssets(root);
      }
      _webRoot = root;
      return;
    }

    final marker = File('${root.path}/.asset_version');
    // 版本号 = 基础版本 + index.html 的内容哈希。
    // 这样**改了 index.html 一定会重新释放**，不会再出现
    // 「代码改了但设备上还是旧页面 → 页面脚本整段不执行 → 模型加载不出来」
    // （曾因为漏升手动版本号排查了很久）。
    final expectedVersion = await computeAssetVersion();
    final upToDate =
        marker.existsSync() && marker.readAsStringSync().trim() == expectedVersion;

    if (!upToDate) {
      // 版本变化：先清空旧资源再重新释放，避免删除/替换模型后残留旧文件
      if (root.existsSync()) {
        try {
          root.deleteSync(recursive: true);
        } catch (_) {
          // 删除失败就覆盖写入
        }
      }
      root.createSync(recursive: true);
      await _extractAssets(root);
      marker.writeAsStringSync(expectedVersion);
    }
    _webRoot = root;
  }

  /// 删掉 userdata 里「从 app 资源复制出来的」内置文件（仅桌面端）
  ///
  /// 内置部分现在直接从 app 目录读取，留着就是白白多占一份（约 20MB）。
  /// **只保留用户导入的 `models/`** —— 那是用户自己的数据，不能删。
  void _removeCopiedBuiltInAssets(Directory root) {
    try {
      for (final entity in root.listSync(followLinks: false)) {
        final name = entity.path.split(Platform.pathSeparator).last;
        if (name == 'models') continue;
        entity.deleteSync(recursive: true);
      }
    } catch (_) {
      // 删不掉就算了，不影响使用（只是没省下空间）
    }
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

      var file = File('${root.path}$path');
      if (!file.existsSync()) {
        // 回退到 **app 自带资源**（桌面端不复制内置文件，直接读 app 目录）
        final builtIn = builtInLive2dDir;
        if (builtIn != null) {
          final fallback = File('${builtIn.path}$path');
          if (fallback.existsSync()) file = fallback;
        }
      }
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
