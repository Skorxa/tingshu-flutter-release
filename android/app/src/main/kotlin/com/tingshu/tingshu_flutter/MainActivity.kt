package com.tingshu.tingshu_flutter

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.provider.OpenableColumns
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.view.ViewGroup
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.FileProvider
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import java.io.File
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var pendingFilePickResult: MethodChannel.Result? = null
    private var pendingLoginResult: MethodChannel.Result? = null
    private var pendingSniffResult: MethodChannel.Result? = null
    private var activeSniffer: AudioSnifferSession? = null
    private var pendingNotificationPermissionResult: MethodChannel.Result? = null

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
                    call.argument<String>("storageKey") ?: "",
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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tingshu/app_update"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getAppVersion" -> getAppVersion(result)
                "installApk" -> installApk(call.argument<String>("path") ?: "", result)
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tingshu/background_protection"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getStatus" -> getBackgroundProtectionStatus(result)
                "requestNotificationPermission" -> requestNotificationPermission(result)
                "requestBatteryOptimizationExemption" -> requestBatteryOptimizationExemption(result)
                "openNotificationSettings" -> openNotificationSettings(result)
                "openAppSettings" -> openAppSettings(result)
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tingshu/device_identity"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getIdentity" -> getDeviceIdentity(result)
                "sign" -> signDevicePayload(
                    call.argument<String>("payload") ?: "",
                    result
                )
                else -> result.notImplemented()
            }
        }
    }

    private fun getDeviceIdentity(result: MethodChannel.Result) {
        try {
            val entry = getOrCreateDeviceKey()
            val publicKey = entry.certificate.publicKey.encoded
            val deviceId = MessageDigest.getInstance("SHA-256")
                .digest(publicKey)
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
            val manufacturer = Build.MANUFACTURER.trim()
            val model = Build.MODEL.trim()
            val deviceName = listOf(manufacturer, model)
                .filter { it.isNotBlank() }
                .distinctBy { it.lowercase() }
                .joinToString(" ")
            result.success(
                mapOf(
                    "deviceId" to deviceId,
                    "publicKey" to Base64.encodeToString(publicKey, Base64.NO_WRAP),
                    "algorithm" to "P-256",
                    "deviceName" to deviceName,
                    "platform" to "android"
                )
            )
        } catch (e: Exception) {
            result.error("DEVICE_IDENTITY_FAILED", e.message ?: "无法创建设备凭据", null)
        }
    }

    private fun signDevicePayload(payload: String, result: MethodChannel.Result) {
        if (payload.isEmpty()) {
            result.error("EMPTY_PAYLOAD", "签名内容为空", null)
            return
        }
        try {
            val signature = Signature.getInstance("SHA256withECDSA")
            signature.initSign(getOrCreateDeviceKey().privateKey)
            signature.update(payload.toByteArray(Charsets.UTF_8))
            result.success(Base64.encodeToString(signature.sign(), Base64.NO_WRAP))
        } catch (e: Exception) {
            result.error("DEVICE_SIGN_FAILED", e.message ?: "设备签名失败", null)
        }
    }

    private fun getOrCreateDeviceKey(): KeyStore.PrivateKeyEntry {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!keyStore.containsAlias(DEVICE_KEY_ALIAS)) {
            val generator = KeyPairGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_EC,
                "AndroidKeyStore"
            )
            val spec = KeyGenParameterSpec.Builder(
                DEVICE_KEY_ALIAS,
                KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
            )
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setUserAuthenticationRequired(false)
                .build()
            generator.initialize(spec)
            generator.generateKeyPair()
        }
        return keyStore.getEntry(DEVICE_KEY_ALIAS, null) as KeyStore.PrivateKeyEntry
    }

    private fun getBackgroundProtectionStatus(result: MethodChannel.Result) {
        val notificationPermissionGranted = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        val notificationsEnabled = notificationPermissionGranted &&
            NotificationManagerCompat.from(this).areNotificationsEnabled()
        val batteryOptimizationExempt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val powerManager = getSystemService(POWER_SERVICE) as PowerManager
            powerManager.isIgnoringBatteryOptimizations(packageName)
        } else {
            true
        }
        result.success(
            mapOf(
                "sdkInt" to Build.VERSION.SDK_INT,
                "notificationPermissionGranted" to notificationPermissionGranted,
                "notificationsEnabled" to notificationsEnabled,
                "batteryOptimizationExempt" to batteryOptimizationExempt
            )
        )
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(NotificationManagerCompat.from(this).areNotificationsEnabled())
            return
        }
        if (ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(NotificationManagerCompat.from(this).areNotificationsEnabled())
            return
        }
        if (pendingNotificationPermissionResult != null) {
            result.error("PERMISSION_BUSY", "通知权限请求正在进行", null)
            return
        }
        pendingNotificationPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_NOTIFICATION_PERMISSION
        )
    }

    private fun requestBatteryOptimizationExemption(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.success(true)
            return
        }
        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        if (powerManager.isIgnoringBatteryOptimizations(packageName)) {
            result.success(true)
            return
        }
        try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName")
                )
            )
            result.success(false)
        } catch (_: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                result.success(false)
            } catch (e: Exception) {
                result.error(
                    "BATTERY_SETTINGS_FAILED",
                    e.message ?: "无法打开电池优化设置",
                    null
                )
            }
        }
    }

    private fun openNotificationSettings(result: MethodChannel.Result) {
        try {
            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            }
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("NOTIFICATION_SETTINGS_FAILED", e.message ?: "无法打开通知设置", null)
        }
    }

    private fun openAppSettings(result: MethodChannel.Result) {
        try {
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName")
                )
            )
            result.success(true)
        } catch (e: Exception) {
            result.error("APP_SETTINGS_FAILED", e.message ?: "无法打开应用设置", null)
        }
    }

    private fun getAppVersion(result: MethodChannel.Result) {
        try {
            val info = packageManager.getPackageInfo(packageName, 0)
            val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode.toInt()
            } else {
                @Suppress("DEPRECATION")
                info.versionCode
            }
            result.success(
                mapOf(
                    "versionName" to (info.versionName ?: ""),
                    "versionCode" to versionCode
                )
            )
        } catch (e: Exception) {
            result.error("VERSION_FAILED", e.message ?: "无法获取版本信息", null)
        }
    }

    private fun installApk(filePath: String, result: MethodChannel.Result) {
        if (filePath.isBlank()) {
            result.error("EMPTY_PATH", "APK 路径为空", null)
            return
        }
        val apk = File(filePath)
        if (!apk.exists()) {
            result.error("APK_NOT_FOUND", "APK 文件不存在: $filePath", null)
            return
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()
            ) {
                val settingsIntent = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                ).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(settingsIntent)
                result.error("INSTALL_PERMISSION", "请先允许安装未知来源应用，然后重新点击安装", null)
                return
            }
            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                apk
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("INSTALL_FAILED", e.message ?: "无法打开安装器", null)
        }
    }

    private fun openLoginWebView(
        url: String,
        title: String,
        userAgent: String,
        storageKey: String,
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
                if (storageKey.isNotBlank()) putExtra("storageKey", storageKey)
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
            val parent = findViewById<ViewGroup>(android.R.id.content)
            lateinit var session: AudioSnifferSession
            session = AudioSnifferSession(
                activity = this,
                parent = parent,
                pageUrl = url,
                rawHeaders = headers,
                clickSelector = click,
                waitMs = waitMs,
                audioPatterns = audioPatterns,
                userAgent = userAgent,
                onSuccess = { audioUrl, resultHeaders ->
                    completeAudioSniff(session, audioUrl, resultHeaders, null)
                },
                onError = { message ->
                    completeAudioSniff(session, "", "", message)
                }
            )
            activeSniffer = session
            session.start()
        } catch (e: Exception) {
            activeSniffer?.cancel()
            activeSniffer = null
            pendingSniffResult = null
            result.error("SNIFF_OPEN_FAILED", e.message ?: "无法启动后台嗅探", null)
        }
    }

    private fun completeAudioSniff(
        session: AudioSnifferSession,
        url: String,
        headers: String,
        error: String?
    ) {
        if (activeSniffer !== session) return
        activeSniffer = null
        val result = pendingSniffResult ?: return
        pendingSniffResult = null
        if (error != null) {
            result.error("SNIFF_FAILED", error, null)
            return
        }
        result.success(mapOf("url" to url, "headers" to headers))
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
                    "url" to (data?.getStringExtra("url") ?: ""),
                    "storageKey" to (data?.getStringExtra("storageKey") ?: ""),
                    "storageValue" to (data?.getStringExtra("storageValue") ?: "")
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

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_NOTIFICATION_PERMISSION) return
        val result = pendingNotificationPermissionResult ?: return
        pendingNotificationPermissionResult = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED &&
            NotificationManagerCompat.from(this).areNotificationsEnabled()
        result.success(granted)
    }

    override fun onDestroy() {
        activeSniffer?.cancel()
        activeSniffer = null
        pendingSniffResult?.error("SNIFF_CANCELLED", "应用界面已关闭，嗅探任务取消", null)
        pendingSniffResult = null
        super.onDestroy()
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
        private const val REQUEST_NOTIFICATION_PERMISSION = 9004
        private const val DEVICE_KEY_ALIAS = "juting_cloud_device_v1"
    }
}
