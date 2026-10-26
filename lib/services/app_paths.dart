import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 应用数据统一根目录与子目录布局。
///
/// Windows：优先 exe 同级的 `userdata\`（绿色便携部署，数据跟着程序走）；
///          不可写（如装在 Program Files）时回退 `%APPDATA%\com.callassistant\call_assistant`。
/// Android：应用外部 files 目录（getExternalStorageDirectory），与旧版 live2d 位置一致。
///
/// 子目录布局（root 下）：
///   live2d/       WebView 运行时 + 内置/导入模型（webRoot，导入模型在其 models/ 子目录）
///   audio/        开场白音频（固定文件名）
///   sherpa/tts/   离线合成模型
///   sherpa/asr/   离线识别模型
///
/// 旧版本散落在 support/documents 目录的数据会在 [init] 时一次性迁移（move）过来。
/// 必须在 `runApp` 前调用 [init]。
class AppPaths {
  AppPaths._();

  static bool _inited = false;
  static Directory? _root;

  /// 数据根目录（init 后可用）
  static Directory get root {
    final r = _root;
    if (r == null) {
      throw StateError('AppPaths.init() 尚未完成 —— 请在 main() 里先 await AppPaths.init()');
    }
    return r;
  }

  static bool get isReady => _inited;

  static Directory get live2dDir => Directory('${root.path}/live2d');
  static Directory get audioDir => Directory('${root.path}/audio');
  static Directory get sherpaTtsDir => Directory('${root.path}/sherpa/tts');
  static Directory get sherpaAsrDir => Directory('${root.path}/sherpa/asr');

  /// 实际使用的根目录位置描述（便携/回退），供设置页与日志展示
  static String get rootKindLabel => _portable ? 'exe 同级 userdata' : '系统应用支持目录';
  static bool _portable = false;

  static Future<void> init() async {
    if (_inited) return;
    final r = await _resolveRoot();
    _root = r;
    try {
      await _migrateOldLocations(r);
    } catch (e) {
      // 迁移失败不阻塞启动：新旧位置都能被各自逻辑找到（读取处有兜底）
      // ignore: avoid_print
      print('[AppPaths] 迁移旧数据失败（忽略）: $e');
    }
    _inited = true;
    // ignore: avoid_print
    print('[AppPaths] 数据根目录: ${r.path}（$rootKindLabel）');
  }

  // ---------------- 根目录解析 ----------------

  static Future<Directory> _resolveRoot() async {
    if (Platform.isWindows) {
      final portable = await _tryPortableRoot();
      if (portable != null) {
        _portable = true;
        return portable;
      }
    }
    if (Platform.isAndroid) {
      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null) return ext;
      } catch (_) {
        // 落到 support 目录
      }
    }
    try {
      return await getApplicationSupportDirectory();
    } catch (_) {
      return Directory.systemTemp.createTempSync('call_assistant_data');
    }
  }

  /// Windows：exe 同级 userdata，试写验证权限；失败返回 null
  static Future<Directory?> _tryPortableRoot() async {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      final dir = Directory('${exeDir.path}/userdata');
      dir.createSync(recursive: true);
      final probe = File('${dir.path}/.write-test');
      probe.writeAsStringSync('ok');
      probe.deleteSync();
      return dir;
    } catch (_) {
      return null;
    }
  }

  // ---------------- 旧位置一次性迁移 ----------------

  static Future<void> _migrateOldLocations(Directory root) async {
    // 收集旧根：support（live2d 曾在这）与 documents（sherpa/音频曾在这），
    // 与新 root 相同则跳过（Android 的 live2d 本就在 external files，无感）。
    final oldBases = <String>{};
    try {
      final s = await getApplicationSupportDirectory();
      if (s.path != root.path) oldBases.add(s.path);
    } catch (_) {}
    try {
      final d = await getApplicationDocumentsDirectory();
      if (d.path != root.path) oldBases.add(d.path);
    } catch (_) {}

    for (final base in oldBases) {
      _moveDir(Directory('$base/live2d'), Directory('${root.path}/live2d'));
      _moveDir(Directory('$base/sherpa-tts'), Directory('${root.path}/sherpa/tts'));
      _moveDir(Directory('$base/sherpa-asr'), Directory('${root.path}/sherpa/asr'));
      _moveFile(File('$base/opening_audio.wav'), File('${root.path}/audio/opening_audio.wav'));
      _moveFile(
        File('$base/opening_audio.wav.env.json'),
        File('${root.path}/audio/opening_audio.wav.env.json'),
      );
    }
  }

  static void _moveDir(Directory src, Directory dst) {
    try {
      if (!src.existsSync() || dst.existsSync()) return;
      dst.parent.createSync(recursive: true);
      try {
        src.renameSync(dst.path);
        return;
      } catch (_) {
        // 跨卷（如 Documents 在 D:、exe 在 C:）rename 会失败 → 复制后删
      }
      dst.createSync(recursive: true);
      _copyTree(src, dst);
      try {
        src.deleteSync(recursive: true);
      } catch (_) {
        // 源删不掉（占用）也先用着复制过来的副本
      }
    } catch (e) {
      // ignore: avoid_print
      print('[AppPaths] 迁移目录失败 ${src.path}: $e');
    }
  }

  static void _moveFile(File src, File dst) {
    try {
      if (!src.existsSync() || dst.existsSync()) return;
      dst.parent.createSync(recursive: true);
      try {
        src.renameSync(dst.path);
        return;
      } catch (_) {
        src.copySync(dst.path);
        try {
          src.deleteSync();
        } catch (_) {}
      }
    } catch (e) {
      // ignore: avoid_print
      print('[AppPaths] 迁移文件失败 ${src.path}: $e');
    }
  }

  static void _copyTree(Directory src, Directory dst) {
    for (final entity in src.listSync(recursive: true, followLinks: false)) {
      final rel = entity.path.substring(src.path.length + 1);
      if (entity is Directory) {
        Directory('${dst.path}/$rel').createSync(recursive: true);
      } else if (entity is File) {
        final out = File('${dst.path}/$rel');
        out.parent.createSync(recursive: true);
        entity.copySync(out.path);
      }
    }
  }
}
