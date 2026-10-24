package com.callassistant.call_assistant

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val callStateChannel = "call_assistant/call_state"
    private val bridgeChannel = "call_assistant/bridge"

    /** 选文件夹的请求码 */
    private val directoryPickerCode = 4312

    /** 选文件夹的异步结果 */
    private var pendingDirectoryResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, callStateChannel).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    CallAnswerAccessibilityService.eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    CallAnswerAccessibilityService.eventSink = null
                }
            }
        )

        MethodChannel(messenger, bridgeChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "isAccessibilityEnabled" -> result.success(isAccessibilityEnabled())
                // 默认设备名用机型，避免 Dart 端拿到 "localhost"
                "deviceModel" -> result.success(android.os.Build.MODEL ?: "")
                "openAccessibilitySettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_FAILED", e.message, null)
                    }
                }
                // 启动/停止前台保活服务（进程不被回收 -> 无障碍授权不会掉）
                "startKeepAlive" -> {
                    try {
                        CallAssistantService.start(this)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("START_FAILED", e.message, null)
                    }
                }
                "stopKeepAlive" -> {
                    try {
                        CallAssistantService.stop(this)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("STOP_FAILED", e.message, null)
                    }
                }
                // Android 13+ 需要通知权限才能看到前台服务通知（不授权也不影响服务运行）
                "requestNotificationPermission" -> {
                    try {
                        if (android.os.Build.VERSION.SDK_INT >= 33) {
                            requestPermissions(arrayOf("android.permission.POST_NOTIFICATIONS"), 1001)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                // Android 11+ 读取用户选中的外部目录需要「所有文件访问权限」
                "hasAllFilesAccess" -> result.success(hasAllFilesAccess())
                "requestAllFilesAccess" -> {
                    try {
                        val intent = if (android.os.Build.VERSION.SDK_INT >= 30) {
                            Intent(
                                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                android.net.Uri.parse("package:$packageName")
                            )
                        } else {
                            Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                        }
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        try {
                            startActivity(
                                Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                            result.success(true)
                        } catch (e2: Exception) {
                            result.error("OPEN_FAILED", e2.message, null)
                        }
                    }
                }
                // 选文件夹：用系统 SAF 自己发起并解析真实路径
                // （MIUI 的 DocumentsUI 通过 file_picker 返回的路径不可用）
                "pickDirectory" -> {
                    pendingDirectoryResult = result
                    try {
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
                            )
                        }
                        startActivityForResult(intent, directoryPickerCode)
                    } catch (e: Exception) {
                        pendingDirectoryResult = null
                        result.error("OPEN_FAILED", e.message, null)
                    }
                }
                // 保存文件到系统「下载」目录（MediaStore，不需要任何存储权限）
                "saveToDownloads" -> {
                    try {
                        val name = call.argument<String>("name") ?: ""
                        val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                        val saved = saveToDownloads(name, bytes)
                        result.success(saved)
                    } catch (e: Exception) {
                        result.error("SAVE_FAILED", e.message, null)
                    }
                }
                // 解码音频文件成 16kHz 单声道 WAV（供离线语音识别）
                "decodeAudioToWav" -> {
                    try {
                        val path = call.argument<String>("path") ?: ""
                        val cacheDir = java.io.File(cacheDir, "asr")
                        val out = java.io.File(cacheDir, "decoded_${System.currentTimeMillis()}.wav")
                        val wavPath = AudioDecoder.decodeToWav(path, out)
                        if (wavPath == null) {
                            result.error("DECODE_FAILED", "无法解码该音频文件（格式不支持或文件损坏）", null)
                        } else {
                            result.success(wavPath)
                        }
                    } catch (e: Exception) {
                        result.error("DECODE_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /// 用 MediaStore 把文件写进系统「下载」目录，返回展示用的路径
    private fun saveToDownloads(name: String, bytes: ByteArray): String? {
        return try {
            val resolver = contentResolver
            val mime = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            if (android.os.Build.VERSION.SDK_INT >= 29) {
                val values = android.content.ContentValues().apply {
                    put(android.provider.MediaStore.Downloads.DISPLAY_NAME, name)
                    put(android.provider.MediaStore.Downloads.MIME_TYPE, mime)
                    put(android.provider.MediaStore.Downloads.RELATIVE_PATH, android.os.Environment.DIRECTORY_DOWNLOADS)
                    put(android.provider.MediaStore.Downloads.IS_PENDING, 1)
                }
                val uri = resolver.insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                if (uri == null) return null
                resolver.openOutputStream(uri)?.use { it.write(bytes) }
                values.clear()
                values.put(android.provider.MediaStore.Downloads.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                "Download/$name"
            } else {
                // Android 10 及以下：直接写公共目录
                val dir = android.os.Environment.getExternalStoragePublicDirectory(
                    android.os.Environment.DIRECTORY_DOWNLOADS
                )
                dir.mkdirs()
                val file = java.io.File(dir, name)
                file.writeBytes(bytes)
                "Download/$name"
            }
        } catch (e: Exception) {
            android.util.Log.w("CallAssistant", "saveToDownloads failed: ${e.message}")
            null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != directoryPickerCode) return
        val pending = pendingDirectoryResult
        pendingDirectoryResult = null
        if (pending == null) return
        val uri = data?.data
        if (resultCode != android.app.Activity.RESULT_OK || uri == null) {
            pending.success(null)
            return
        }
        pending.success(resolveTreePath(uri))
    }

    /// 把 SAF 的 tree Uri 解析成真实文件系统路径（primary:Download -> /storage/emulated/0/Download）
    private fun resolveTreePath(uri: android.net.Uri): String? {
        return try {
            val docId = android.provider.DocumentsContract.getTreeDocumentId(uri)
            android.util.Log.i("CallAssistant", "tree docId=$docId")
            val parts = docId.split(":")
            val volume = parts.firstOrNull() ?: return null
            val rest = if (parts.size > 1) parts.drop(1).joinToString(":") else ""
            // 内部存储在不同 ROM 上叫 primary / root / emulated
            if (volume == "primary" || volume == "root" || volume == "emulated") {
                "/storage/emulated/0/$rest"
            } else {
                // 其它卷（SD 卡）：/storage/<volume-uuid>/<rest>
                "/storage/$volume/$rest"
            }
        } catch (e: Exception) {
            android.util.Log.w("CallAssistant", "resolveTreePath failed: ${e.message}")
            null
        }
    }

    /** 是否已获得「所有文件访问权限」（Android 11+ 读取外部目录需要） */
    private fun hasAllFilesAccess(): Boolean {
        return if (android.os.Build.VERSION.SDK_INT >= 30) {
            android.os.Environment.isExternalStorageManager()
        } else {
            true
        }
    }

    /** 判断本应用的通话检测无障碍服务是否已开启 */
    private fun isAccessibilityEnabled(): Boolean {
        val expected = "$packageName/${CallAnswerAccessibilityService::class.java.name}"
        return try {
            val enabled = Settings.Secure.getString(
                contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
            ) ?: return false
            enabled.split(':').any { it.equals(expected, ignoreCase = true) }
        } catch (e: Exception) {
            false
        }
    }
}
