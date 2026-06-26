package com.tingshu.tingshu_flutter

import android.app.Activity
import android.content.Intent
import android.provider.OpenableColumns
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var pendingFilePickResult: MethodChannel.Result? = null
    private var pendingLoginResult: MethodChannel.Result? = null
    private var pendingSniffResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tingshu/source_file_picker"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickSourceFile" -> pickSourceFile(result)
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tingshu/source_login"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openLogin" -> openLoginWebView(
                    call.argument<String>("url") ?: "",
                    call.argument<String>("title") ?: "音源登录",
                    call.argument<String>("userAgent") ?: "",
                    result
                )
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tingshu/audio_sniffer"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "sniff" -> openAudioSniffer(
                    call.argument<String>("url") ?: "",
                    call.argument<String>("headers") ?: "",
                    call.argument<String>("click") ?: "",
                    call.argument<Int>("waitMs") ?: 3000,
                    call.argument<ArrayList<String>>("audioPatterns") ?: arrayListOf(),
                    call.argument<String>("userAgent") ?: "",
                    result
                )
                else -> result.notImplemented()
            }
        }
    }

    private fun openLoginWebView(
        url: String,
        title: String,
        userAgent: String,
        result: MethodChannel.Result
    ) {
        if (url.isBlank()) {
            result.error("EMPTY_URL", "登录地址为空", null)
            return
        }
        if (pendingLoginResult != null) {
            result.error("LOGIN_BUSY", "登录页面已经打开", null)
            return
        }
        pendingLoginResult = result
        try {
            val intent = Intent(this, LoginWebViewActivity::class.java).apply {
                putExtra("url", url)
                putExtra("title", title)
                putExtra("userAgent", userAgent)
            }
            startActivityForResult(intent, REQUEST_SOURCE_LOGIN)
        } catch (e: Exception) {
            pendingLoginResult = null
            result.error("OPEN_URL_FAILED", e.message ?: "无法打开登录页面", null)
        }
    }

    private fun pickSourceFile(result: MethodChannel.Result) {
        if (pendingFilePickResult != null) {
            result.error("PICKER_BUSY", "文件选择器正在打开", null)
            return
        }
        pendingFilePickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "text/*",
                    "application/javascript",
                    "application/json",
                    "application/octet-stream"
                )
            )
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        try {
            startActivityForResult(intent, REQUEST_PICK_SOURCE_FILE)
        } catch (e: Exception) {
            pendingFilePickResult = null
            result.error("PICKER_OPEN_FAILED", e.message ?: "无法打开文件管理器", null)
        }
    }

    private fun openAudioSniffer(
        url: String,
        headers: String,
        click: String,
        waitMs: Int,
        audioPatterns: ArrayList<String>,
        userAgent: String,
        result: MethodChannel.Result
    ) {
        if (url.isBlank()) {
            result.error("EMPTY_URL", "嗅探页面地址为空", null)
            return
        }
        if (pendingSniffResult != null) {
            result.error("SNIFF_BUSY", "已有嗅探任务正在运行", null)
            return
        }
        pendingSniffResult = result
        try {
            val intent = Intent(this, AudioSnifferActivity::class.java).apply {
                putExtra("url", url)
                putExtra("headers", headers)
                putExtra("click", click)
                putExtra("waitMs", waitMs)
                putStringArrayListExtra("audioPatterns", audioPatterns)
                putExtra("userAgent", userAgent)
            }
            startActivityForResult(intent, REQUEST_AUDIO_SNIFF)
        } catch (e: Exception) {
            pendingSniffResult = null
            result.error("SNIFF_OPEN_FAILED", e.message ?: "无法打开嗅探页面", null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_SOURCE_LOGIN) {
            val result = pendingLoginResult ?: return
            pendingLoginResult = null
            if (resultCode != Activity.RESULT_OK) {
                result.success(null)
                return
            }
            result.success(
                mapOf(
                    "cookie" to (data?.getStringExtra("cookie") ?: ""),
                    "url" to (data?.getStringExtra("url") ?: "")
                )
            )
            return
        }
        if (requestCode == REQUEST_AUDIO_SNIFF) {
            val result = pendingSniffResult ?: return
            pendingSniffResult = null
            if (resultCode != Activity.RESULT_OK) {
                result.error(
                    "SNIFF_FAILED",
                    data?.getStringExtra("error") ?: "没有嗅探到音频资源",
                    null
                )
                return
            }
            result.success(
                mapOf(
                    "url" to (data?.getStringExtra("url") ?: ""),
                    "headers" to (data?.getStringExtra("headers") ?: "")
                )
            )
            return
        }
        if (requestCode != REQUEST_PICK_SOURCE_FILE) return
        val result = pendingFilePickResult ?: return
        pendingFilePickResult = null

        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return
        }

        val uri = data?.data
        if (uri == null) {
            result.error("PICKER_EMPTY", "未选择文件", null)
            return
        }

        try {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
        } catch (_: Exception) {
            // 部分文件管理器不会授予持久权限,即时读取即可。
        }

        try {
            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                ?: ByteArray(0)
            val name = queryDisplayName(uri)
            result.success(
                mapOf(
                    "name" to name,
                    "size" to bytes.size,
                    "content" to bytes.toString(Charsets.UTF_8)
                )
            )
        } catch (e: Exception) {
            result.error("PICKER_READ_FAILED", e.message ?: "读取文件失败", null)
        }
    }

    private fun queryDisplayName(uri: android.net.Uri): String {
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (index >= 0 && cursor.moveToFirst()) {
                return cursor.getString(index) ?: "source.js"
            }
        }
        return uri.lastPathSegment ?: "source.js"
    }

    companion object {
        private const val REQUEST_PICK_SOURCE_FILE = 9001
        private const val REQUEST_SOURCE_LOGIN = 9002
        private const val REQUEST_AUDIO_SNIFF = 9003
    }
}
