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
                else -> result.notImplemented()
            }
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
