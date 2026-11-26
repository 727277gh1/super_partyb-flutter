package com.atjog.spb.spb_mobile

import android.content.Intent
import android.content.ClipboardManager
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import androidx.core.content.IntentCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.concurrent.Executors

/** 独立 Activity 使用调用方的返回栈，发送完成只 finish，不把主界面推到前台。 */
class QuickCaptureActivity : MainActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var captureDirectory: File
    private var payload: Map<String, Any?>? = null
    private var loading = false
    private val waiting = mutableListOf<MethodChannel.Result>()
    private var clipboardLaunch = false
    private var clipboardPayload: Map<String, Any?>? = null
    private val clipboardWaiting = mutableListOf<MethodChannel.Result>()

    override fun onCreate(savedInstanceState: Bundle?) {
        captureDirectory = File(cacheDir, "external-quick-capture/${UUID.randomUUID()}")
        clipboardLaunch = intent.action == CLIPBOARD_ACTION
        super.onCreate(savedInstanceState)
        active = WeakReference(this)
    }

    override fun getInitialRoute() = "/overlay"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "load" -> {
                    // 首帧前只返回入口类型；等待焦点必须在 Flutter 已绘制后，避免启动互等。
                    if (clipboardLaunch) {
                        result.success(mapOf("readClipboard" to true))
                        return@setMethodCallHandler
                    }
                    payload?.let { result.success(it); return@setMethodCallHandler }
                    waiting.add(result)
                    if (!loading) {
                        loading = true
                        val source = intent
                        worker.execute {
                            val loaded = readCapture(source)
                            runOnUiThread {
                                if (isDestroyed) {
                                    captureDirectory.deleteRecursively()
                                } else {
                                    payload = loaded
                                    waiting.forEach { it.success(loaded) }
                                    waiting.clear()
                                }
                            }
                        }
                    }
                }
                "readClipboard" -> {
                    if (!clipboardLaunch) {
                        result.error("unsupported", "此入口不读取剪贴板", null)
                        return@setMethodCallHandler
                    }
                    clipboardPayload?.let { result.success(it); return@setMethodCallHandler }
                    clipboardWaiting.add(result)
                    completeClipboardRead()
                }
                "finish" -> {
                    result.success(null)
                    // PROCESS_TEXT 不返回替换文本，避免修改来源应用中用户选中的文字。
                    setResult(RESULT_CANCELED)
                    if (clipboardLaunch && isTaskRoot) finishAndRemoveTask() else finish()
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) completeClipboardRead()
    }

    private fun completeClipboardRead() {
        // Android 10+ 要求读取方有输入焦点。请求只在 Flutter 登录/解锁守卫之后发来。
        if (clipboardWaiting.isEmpty() || !hasWindowFocus() || isFinishing || isDestroyed) return
        val loaded = try {
            val clip = getSystemService(ClipboardManager::class.java).primaryClip
            var text = ""
            var error: String? = null
            if (clip == null || clip.itemCount == 0) {
                error = "剪贴板没有文字，请先复制文字，或在这里直接输入。"
            } else {
                // 只取文本，不能通过 coerceToText 隐式读取剪贴板 URI 指向的文件。
                val value = clip.getItemAt(0).text
                if (value.isNullOrBlank()) {
                    error = "剪贴板没有文字，请先复制文字，或在这里直接输入。"
                } else if (value.length > 200_000) {
                    error = "剪贴板文字过长，请缩短后重新复制。"
                } else {
                    text = value.toString()
                }
            }
            mapOf("text" to text, "error" to error)
        } catch (_: Exception) {
            mapOf("error" to "无法读取剪贴板，请长按输入框粘贴，或直接输入。")
        }
        // 一次呼出只读取一次；登录回调、系统面板或切回前台不能覆盖已编辑的草稿。
        clipboardPayload = loaded
        clipboardWaiting.forEach { it.success(loaded) }
        clipboardWaiting.clear()
    }

    private fun readCapture(source: Intent): Map<String, Any?> {
        var text = ""
        return try {
            val action = source.action
            require(action == Intent.ACTION_SEND || action == Intent.ACTION_SEND_MULTIPLE ||
                action == Intent.ACTION_PROCESS_TEXT) { "不支持此快速对话入口" }
            text = source.getCharSequenceExtra(
                if (action == Intent.ACTION_PROCESS_TEXT) Intent.EXTRA_PROCESS_TEXT else Intent.EXTRA_TEXT
            )?.toString().orEmpty()
            require(text.length <= 200_000) { "分享的文字过长，请缩短后重试" }
            val uris = linkedSetOf<Uri>()
            if (action == Intent.ACTION_SEND) {
                IntentCompat.getParcelableExtra(source, Intent.EXTRA_STREAM, Uri::class.java)?.let(uris::add)
            } else if (action == Intent.ACTION_SEND_MULTIPLE) {
                IntentCompat.getParcelableArrayListExtra(source, Intent.EXTRA_STREAM, Uri::class.java)?.let(uris::addAll)
            }
            if (action != Intent.ACTION_PROCESS_TEXT) {
                source.clipData?.let { clip ->
                    require(clip.itemCount <= 10) { "一次最多分享 10 个文件" }
                    for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let(uris::add)
                }
            }
            require(uris.size <= 10) { "一次最多分享 10 个文件" }
            // 系统可能回收进程，过期副本只在专用缓存目录内清理。
            captureDirectory.parentFile?.listFiles()?.filter {
                it.lastModified() < System.currentTimeMillis() - 86_400_000
            }?.forEach { it.deleteRecursively() }
            captureDirectory.mkdirs()
            var total = 0L
            val files = uris.mapIndexed { index, uri ->
                require(uri.scheme == "content" && uri.authority?.startsWith(packageName) != true) {
                    "分享的文件地址不可用，请通过系统分享菜单重试"
                }
                val originalName = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                    ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
                    ?: "附件-${index + 1}"
                val name = originalName.substringAfterLast('/').substringAfterLast('\\')
                    .replace(Regex("[\\x00-\\x1f\\x7f]"), "_").take(180)
                    .ifBlank { "附件-${index + 1}" }
                // 缓存名不沿用外部名称，避免多字节长文件名超过文件系统字节上限。
                val target = File(captureDirectory, "$index")
                val input = contentResolver.openInputStream(uri) ?: error("无法读取分享的文件")
                input.use { stream ->
                    target.outputStream().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        var size = 0L
                        while (true) {
                            val count = stream.read(buffer)
                            if (count < 0) break
                            size += count
                            total += count
                            require(size <= 50L * 1024 * 1024 && total <= 100L * 1024 * 1024) {
                                "单个附件不能超过 50 MB，附件合计不能超过 100 MB"
                            }
                            output.write(buffer, 0, count)
                        }
                        require(size > 0) { "分享的文件为空" }
                    }
                }
                mapOf("path" to target.absolutePath, "name" to name)
            }
            mapOf("text" to text, "files" to files)
        } catch (error: Exception) {
            captureDirectory.deleteRecursively()
            // 外部 provider 的异常可能含私有路径，不直接展示或记录其 message。
            val message = if (error is IllegalArgumentException) error.message else "无法读取分享内容，请返回来源应用重新分享"
            mapOf("text" to text.take(200_000), "files" to emptyList<Any>(), "error" to message)
        }
    }

    private fun receiveAuthIntent(authIntent: Intent) {
        // app_links 必须在临时 engine 收到回调，否则登录完成后草稿仍被卡在登录页。
        super.onNewIntent(authIntent)
        startActivity(Intent(this, QuickCaptureActivity::class.java).apply {
            action = RESUME_ACTION
            addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
        })
    }

    override fun onNewIntent(intent: Intent) {
        if (intent.action != RESUME_ACTION) super.onNewIntent(intent)
    }

    override fun onDestroy() {
        if (active?.get() === this) active = null
        clipboardWaiting.clear()
        // 排在导入任务后删除，避免读取尚未结束时清理目录又被后台线程重建。
        worker.execute { captureDirectory.deleteRecursively() }
        worker.shutdown()
        super.onDestroy()
    }

    companion object {
        const val CLIPBOARD_ACTION = "com.atjog.spb.QUICK_CAPTURE_CLIPBOARD"
        private const val CHANNEL = "com.atjog.spb/external_quick_capture"
        private const val RESUME_ACTION = "com.atjog.spb.RESUME_QUICK_CAPTURE"
        private var active: WeakReference<QuickCaptureActivity>? = null

        fun forwardAuthIntent(intent: Intent): Boolean {
            val activity = active?.get() ?: return false
            val uri = intent.data ?: return false
            val oidc = (uri.scheme == "partyb" && uri.host == "oidc" && uri.path == "/callback") ||
                (uri.scheme == "https" && uri.host == "dever.atjog.com" && uri.path == "/idp/app/callback")
            if (intent.action != Intent.ACTION_VIEW || !oidc || activity.isFinishing) return false
            activity.receiveAuthIntent(intent)
            return true
        }
    }
}
