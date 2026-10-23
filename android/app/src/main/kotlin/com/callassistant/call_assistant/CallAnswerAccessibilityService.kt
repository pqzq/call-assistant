package com.callassistant.call_assistant

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import io.flutter.plugin.common.EventChannel

/**
 * 通过无障碍服务读取通话界面，判断外呼是否「已接通」。
 *
 * 原理：系统没有给第三方应用开放"外呼已接通"的状态回调（CALL_STATE_OFFHOOK 在拨号时就触发了），
 * 但通话界面在接通后会显示通话计时器（00:05）或"通话中"字样，这里通过无障碍读取界面文本来判断。
 */
class CallAnswerAccessibilityService : AccessibilityService() {

    companion object {
        /** Flutter 侧 EventChannel 的事件出口，由 MainActivity 注入 */
        var eventSink: EventChannel.EventSink? = null

        /** 通话计时器，例如 00:05 / 1:23 */
        private val TIMER_REGEX = Regex("""\b\d{1,2}:\d{2}\b""")

        /** 接通后的界面文案 */
        private val CONNECTED_WORDS = listOf("通话中", "已接通", "正在通话", "通话时长")

        /** 仍在呼叫中的界面文案（出现这些时不算接通） */
        private val DIALING_WORDS = listOf("正在呼叫", "呼叫中", "正在拨号", "正在等待接通", "正在接通")

        /** 通话结束的界面文案 */
        private val ENDED_WORDS = listOf("通话结束", "已挂断", "通话已结束")

        /** 可能是通话界面的包名关键字 */
        private val CALL_UI_PACKAGES = listOf("dialer", "incallui", "contacts", "phone", "call")

        private var connected = false
        private var lastConnectedEmitAt = 0L
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        emitState(false, "服务已连接")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val e = event ?: return
        when (e.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> handleWindowChanged(e)
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED -> scan()
        }
    }

    override fun onInterrupt() {
        // 无需处理
    }

    override fun onDestroy() {
        if (connected) {
            emitState(false, "服务已断开")
        }
        super.onDestroy()
    }

    /** 窗口切换：离开通话界面 = 通话结束 */
    private fun handleWindowChanged(event: AccessibilityEvent) {
        val pkg = event.packageName?.toString()?.lowercase() ?: ""
        if (isCallUi(pkg)) {
            scan()
        } else if (connected) {
            emitState(false, "已离开通话界面")
        }
    }

    private fun scan() {
        val root: AccessibilityNodeInfo = rootInActiveWindow ?: return
        val pkg = root.packageName?.toString()?.lowercase() ?: return
        // 只处理通话类界面，避免把状态栏时钟（12:30）误判成通话计时
        if (!isCallUi(pkg)) {
            if (connected) emitState(false, "非通话界面")
            return
        }

        val texts = ArrayList<String>()
        collectText(root, texts, 0)
        if (texts.isEmpty()) return

        val joined = texts.joinToString(" | ")
        val hasTimer = texts.any { TIMER_REGEX.containsMatchIn(it) }
        val hasConnectedWord = CONNECTED_WORDS.any { joined.contains(it) }
        val hasDialingWord = DIALING_WORDS.any { joined.contains(it) }
        val hasEndedWord = ENDED_WORDS.any { joined.contains(it) }

        when {
            hasEndedWord -> emitState(false, "通话结束")
            (hasTimer || hasConnectedWord) && !hasDialingWord -> {
                val detail = texts.firstOrNull { TIMER_REGEX.containsMatchIn(it) }
                    ?: texts.firstOrNull { text -> CONNECTED_WORDS.any { text.contains(it) } }
                    ?: "通话中"
                emitState(true, detail, pkg)
            }
        }
    }

    private fun isCallUi(pkg: String): Boolean =
        CALL_UI_PACKAGES.any { pkg.contains(it) }

    private fun collectText(node: AccessibilityNodeInfo?, out: MutableList<String>, depth: Int) {
        if (node == null || depth > 25) return
        val text = node.text?.toString()?.trim()
        if (!text.isNullOrEmpty()) out.add(text)
        val desc = node.contentDescription?.toString()?.trim()
        if (!desc.isNullOrEmpty()) out.add(desc)
        for (i in 0 until node.childCount) {
            collectText(node.getChild(i), out, depth + 1)
        }
    }

    private fun emitState(isConnected: Boolean, detail: String, pkg: String = "") {
        val now = System.currentTimeMillis()
        // 接通事件做去抖：2 秒内不重复上报
        if (isConnected && connected && now - lastConnectedEmitAt < 2000) return
        if (isConnected == connected && isConnected) return

        connected = isConnected
        if (isConnected) lastConnectedEmitAt = now

        eventSink?.success(
            mapOf(
                "connected" to isConnected,
                "detail" to detail,
                "package" to pkg,
                "timestamp" to now
            )
        )
    }
}
