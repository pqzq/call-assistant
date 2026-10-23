package com.callassistant.call_assistant

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * 前台保活服务。
 *
 * 背景：MIUI / HyperOS 上应用被「强制停止」或进程被回收后，系统会连带移除无障碍服务授权，
 * 用户每次重开应用都要重新去系统设置里开一次，非常影响使用。
 *
 * 这里用常驻前台服务把进程「钉住」：
 * - 进程不会被系统回收，无障碍服务保持绑定 -> 授权不会掉
 * - 用户也不会再去「强制停止」应用
 */
class CallAssistantService : Service() {

    companion object {
        const val CHANNEL_ID = "call_assistant_keepalive"
        const val NOTIFICATION_ID = 1001
        const val ACTION_START = "com.callassistant.call_assistant.START"
        const val ACTION_STOP = "com.callassistant.call_assistant.STOP"

        fun start(context: Context) {
            val intent = Intent(context, CallAssistantService::class.java).setAction(ACTION_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, CallAssistantService::class.java).setAction(ACTION_STOP)
            context.startService(intent)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }
        startForegroundCompat()
        // START_STICKY：进程被系统杀掉后系统会重新拉起服务，尽量保住无障碍绑定
        return START_STICKY
    }

    private fun startForegroundCompat() {
        createChannel()
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle("话务助手运行中")
            .setContentText("保持通话检测与双机联动服务")
            .setSmallIcon(android.R.drawable.ic_menu_call)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    @Suppress("DEPRECATION")
    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            stopForeground(true)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "后台服务",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "保持通话检测与双机联动服务运行"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }
}
