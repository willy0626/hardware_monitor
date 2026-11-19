
package com.example.hardware_monitor

import android.app.ActivityManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.os.StatFs
import android.os.SystemClock
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.provider.Settings

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import org.xmlpull.v1.XmlPullParser

import java.io.File
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {

    private val CHANNEL = "hardware_monitor/native"
    private val batteryChannelName = "hardware_monitor/battery"
    private var batteryReceiver: BroadcastReceiver? = null

    private var lastCpuTimeMs = -1L
    private var lastWallTimeMs = -1L
    private var gpuIdentity: Map<String, Any?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, batteryChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    stopBatteryUpdates()
                    val receiver = object : BroadcastReceiver() {
                        override fun onReceive(context: Context, intent: Intent) {
                            events.success(getBatteryInfo(intent))
                        }
                    }
                    // The sticky system broadcast delivers the current reading on subscription.
                    applicationContext.registerReceiver(
                        receiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED)
                    )
                    batteryReceiver = receiver
                }

                override fun onCancel(arguments: Any?) {
                    stopBatteryUpdates()
                }
            })

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {
                "getBatteryVoltage" -> {
                    val intent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                    result.success(intent?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1))
                }

                "getHardwareInfo", "getBatteryDetails", "getCpuInfo" -> {
                    val includeCpu = call.argument<Boolean>("includeCpu") != false
                    thread {
                        try {
                            val data = when (call.method) {
                                "getBatteryDetails" -> getBatteryDetails()
                                "getCpuInfo" -> getCpuInfo()
                                else -> getHardwareInfo(includeCpu)
                            }

                            runOnUiThread {
                                result.success(data)
                            }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error(
                                    "HARDWARE_ERROR",
                                    e.message,
                                    null
                                )
                            }
                        }
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        stopBatteryUpdates()
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, batteryChannelName)
            .setStreamHandler(null)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun stopBatteryUpdates() {
        batteryReceiver?.let(applicationContext::unregisterReceiver)
        batteryReceiver = null
    }

    // 獨立讀取每個硬體項目，避免單項失敗影響其他項目
    private fun safeHardwareRead(
        reader: () -> Map<String, Any?>
    ): Map<String, Any?> {
        return try {
            reader()
        } catch (e: Exception) {
            mapOf(
                "available" to false,
                "error" to (e.message ?: "Unknown error")
            )
        }
    }

    // 取得所有硬體資訊
    private fun getHardwareInfo(includeCpu: Boolean): Map<String, Any?> {
        return buildMap {
            putAll(mapOf(
            "device" to safeHardwareRead { getDeviceInfo() },
            "ram" to safeHardwareRead { getRamInfo() },
            "storage" to safeHardwareRead { getStorageInfo() },
            "gpu" to safeHardwareRead { getGpuInfo() },
            "thermal" to safeHardwareRead { getThermalInfo() }
            ))
            if (includeCpu) put("cpu", safeHardwareRead { getCpuInfo() })
        }
    }

    // 裝置資訊與 Samsung One UI 版本
    private fun getDeviceInfo(): Map<String, Any?> {

        // 讀取 Samsung One UI 系統屬性
        val oneUiRaw = try {
            val process = ProcessBuilder(
                "getprop",
                "ro.build.version.oneui"
            ).start()

            process.inputStream.bufferedReader().use {
                it.readText().trim()
            }
        } catch (e: Exception) {
            ""
        }

        // 轉換 One UI 版本代碼
        val oneUiVersion = if (oneUiRaw.isNotBlank()) {
            val versionCode = oneUiRaw.toIntOrNull()

            if (versionCode != null && versionCode >= 10000) {
                val major = versionCode / 10000
                val minor = (versionCode % 10000) / 1000

                if (minor > 0) {
                    "One UI $major.$minor"
                } else {
                    "One UI $major"
                }
            } else if (
                oneUiRaw.startsWith("One UI", ignoreCase = true)
            ) {
                oneUiRaw
            } else {
                "One UI $oneUiRaw"
            }
        } else {
            "無法讀取"
        }

        // 裝置名稱
        val deviceName = try {
            Settings.Global.getString(
                contentResolver,
                "device_name"
            )?.takeIf { it.isNotBlank() } ?: Build.MODEL
        } catch (e: Exception) {
            Build.MODEL
        }

        return mapOf(
            "brand" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "deviceName" to deviceName,
            "androidVersion" to "Android ${Build.VERSION.RELEASE}",
            "androidSdk" to Build.VERSION.SDK_INT,
            "socManufacturer" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Build.SOC_MANUFACTURER else null,
            "socModel" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Build.SOC_MODEL else null,
            "oneUiVersion" to oneUiVersion,
            "oneUiRaw" to oneUiRaw
        )
    }

    // CPU 資訊
    // 注意：這裡監控的是 App 本身的 CPU 使用率，不是整機 CPU 使用率
    private fun getCpuInfo(): Map<String, Any?> {
        val cores = Runtime.getRuntime().availableProcessors()

        val currentCpuTime = android.os.Process.getElapsedCpuTime()
        val currentWallTime = SystemClock.elapsedRealtime()

        var usage = 0.0

        if (lastCpuTimeMs >= 0 && lastWallTimeMs >= 0) {
            val cpuDiff = currentCpuTime - lastCpuTimeMs
            val wallDiff = currentWallTime - lastWallTimeMs

            if (wallDiff > 0 && cpuDiff >= 0) {
                usage = (
                    cpuDiff.toDouble() / wallDiff / cores * 100.0
                ).coerceIn(0.0, 100.0)
            }
        }

        lastCpuTimeMs = currentCpuTime
        lastWallTimeMs = currentWallTime

        // 嘗試讀取 CPU 核心頻率
        val frequencies = mutableMapOf<Int, Int>()
        val frequenciesByPolicy = mutableMapOf<String, Int?>()

        for (i in 0 until cores) {
            try {
                val file = File(
                    "/sys/devices/system/cpu/cpu$i/cpufreq/scaling_cur_freq"
                )

                if (file.canRead()) {
                    val path = file.canonicalPath
                    if (!frequenciesByPolicy.containsKey(path)) {
                        frequenciesByPolicy[path] = file.readText().trim().toIntOrNull()
                    }
                    val khz = frequenciesByPolicy[path]
                    if (khz != null && khz > 0) frequencies[i] = khz / 1000
                }
            } catch (_: Exception) {
                // Android 可能限制讀取核心頻率
            }
        }

        return mapOf(
            "cores" to cores,
            "usage" to usage,
            "usageScope" to "App process",
            "frequenciesMHz" to frequencies.values.toList(),
            "frequenciesByCoreMHz" to frequencies,
            "frequencyAvailable" to frequencies.isNotEmpty()
        )
    }

    // RAM 資訊
    private fun getRamInfo(): Map<String, Any?> {
        val manager = getSystemService(
            Context.ACTIVITY_SERVICE
        ) as ActivityManager

        val memory = ActivityManager.MemoryInfo()
        manager.getMemoryInfo(memory)

        val total = memory.totalMem
        val available = memory.availMem
        val used = total - available

        val usage = if (total > 0) {
            used.toDouble() / total * 100
        } else {
            0.0
        }

        return mapOf(
            "totalMB" to total / 1024 / 1024,
            "usedMB" to used / 1024 / 1024,
            "availableMB" to available / 1024 / 1024,
            "usage" to usage
        )
    }

    private fun getStorageInfo(): Map<String, Long> {
        val storage = StatFs(Environment.getDataDirectory().absolutePath)
        val totalBytes = storage.totalBytes
        val availableBytes = storage.availableBytes
        return mapOf(
            "totalBytes" to totalBytes,
            "usedBytes" to (totalBytes - availableBytes).coerceAtLeast(0L)
        )
    }

    // GPU 資訊
    private fun getGpuInfo(): Map<String, Any?> {
        gpuIdentity?.let { return it }
        var renderer: String? = null
        var version: String? = null

        var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
        var context: EGLContext = EGL14.EGL_NO_CONTEXT
        var surface: EGLSurface = EGL14.EGL_NO_SURFACE

        try {
            display = EGL14.eglGetDisplay(
                EGL14.EGL_DEFAULT_DISPLAY
            )

            val versions = IntArray(2)

            if (
                display == EGL14.EGL_NO_DISPLAY ||
                !EGL14.eglInitialize(
                    display,
                    versions,
                    0,
                    versions,
                    1
                )
            ) {
                throw Exception("EGL display initialization failed")
            }

            val configs = arrayOfNulls<EGLConfig>(1)
            val count = IntArray(1)

            val configAttributes = intArrayOf(
                EGL14.EGL_SURFACE_TYPE,
                EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_RENDERABLE_TYPE,
                EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_NONE
            )

            if (
                !EGL14.eglChooseConfig(
                    display,
                    configAttributes,
                    0,
                    configs,
                    0,
                    1,
                    count,
                    0
                ) || count[0] == 0
            ) {
                throw Exception("No EGL config")
            }

            val config = configs[0]
                ?: throw Exception("EGL config is null")

            val contextAttributes = intArrayOf(
                EGL14.EGL_CONTEXT_CLIENT_VERSION,
                2,
                EGL14.EGL_NONE
            )

            context = EGL14.eglCreateContext(
                display,
                config,
                EGL14.EGL_NO_CONTEXT,
                contextAttributes,
                0
            )

            val surfaceAttributes = intArrayOf(
                EGL14.EGL_WIDTH, 1,
                EGL14.EGL_HEIGHT, 1,
                EGL14.EGL_NONE
            )

            surface = EGL14.eglCreatePbufferSurface(
                display,
                config,
                surfaceAttributes,
                0
            )

            if (
                context == EGL14.EGL_NO_CONTEXT ||
                surface == EGL14.EGL_NO_SURFACE ||
                !EGL14.eglMakeCurrent(
                    display,
                    surface,
                    surface,
                    context
                )
            ) {
                throw Exception("EGL context initialization failed")
            }

            renderer = GLES20.glGetString(
                GLES20.GL_RENDERER
            )

            version = GLES20.glGetString(
                GLES20.GL_VERSION
            )

        } catch (e: Exception) {
            throw Exception("GPU: ${e.message}")
        } finally {
            if (display != EGL14.EGL_NO_DISPLAY) {
                EGL14.eglMakeCurrent(
                    display,
                    EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_CONTEXT
                )

                if (surface != EGL14.EGL_NO_SURFACE) {
                    EGL14.eglDestroySurface(display, surface)
                }

                if (context != EGL14.EGL_NO_CONTEXT) {
                    EGL14.eglDestroyContext(display, context)
                }

                EGL14.eglTerminate(display)
            }
        }

        return mapOf(
            "renderer" to renderer,
            "version" to version,
            "available" to (renderer != null)
        ).also { if (renderer != null) gpuIdentity = it }
    }

    private fun getBatteryDetails(): Map<String, Any?> {
        val intent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val manager = getSystemService(BatteryManager::class.java)

        fun batteryProperty(id: Int): Long? {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return null
            // Android may restrict these Health HAL properties to privileged callers.
            return try {
                manager.getLongProperty(id).takeUnless { it == Long.MIN_VALUE }
            } catch (_: SecurityException) {
                null
            }
        }

        val profile = getBatteryProfileCapacities()
        return mapOf(
            "manufacturer" to Build.MANUFACTURER,
            "sdkInt" to Build.VERSION.SDK_INT,
            "technology" to intent?.getStringExtra(BatteryManager.EXTRA_TECHNOLOGY),
            "voltageMv" to intent?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1),
            "cycleCount" to intent?.getIntExtra("android.os.extra.CYCLE_COUNT", -1),
            // Android 14 BatteryManager property IDs are hidden on some SDKs.
            "manufactureDate" to batteryProperty(7),
            "firstUseDate" to batteryProperty(8),
            "healthPercent" to batteryProperty(10),
            "profileCapacityMah" to profile["battery.capacity"],
            "typicalCapacityMah" to profile["battery.typical.capacity"]
        )
    }

    private fun getBatteryProfileCapacities(): Map<String, Double> {
        val id = resources.getIdentifier("power_profile", "xml", "android")
        if (id == 0) return emptyMap()
        return runCatching {
            resources.getXml(id).use { profile ->
                val capacities = mutableMapOf<String, Double>()
                while (profile.next() != XmlPullParser.END_DOCUMENT) {
                    if (profile.eventType != XmlPullParser.START_TAG || profile.name != "item") {
                        continue
                    }
                    val name = profile.getAttributeValue(null, "name")
                    if (name == "battery.capacity" || name == "battery.typical.capacity") {
                        val value = profile.nextText().trim().toDoubleOrNull()
                        // AOSP's default battery.capacity is a placeholder.
                        if (value != null && value.isFinite() && value > 0 &&
                            (name != "battery.capacity" || value != 1000.0)
                        ) {
                            capacities[name] = value
                        }
                    }
                }
                capacities
            }
        }.getOrNull() ?: emptyMap()
    }

    // 電池資訊
    private fun getBatteryInfo(intent: Intent): Map<String, Any?> {
        val level = intent.getIntExtra(
            BatteryManager.EXTRA_LEVEL, -1
        )

        val scale = intent.getIntExtra(
            BatteryManager.EXTRA_SCALE, -1
        )

        val temperature = intent.getIntExtra(
            BatteryManager.EXTRA_TEMPERATURE, -1
        )

        val status = intent.getIntExtra(
            BatteryManager.EXTRA_STATUS, -1
        )

        val batteryLevel = if (scale > 0 && level >= 0) {
            level * 100 / scale
        } else {
            null
        }

        return mapOf(
            "level" to batteryLevel,
            "temperatureC" to if (temperature >= 0) {
                temperature / 10.0
            } else {
                null
            },
            "status" to when (status) {
                BatteryManager.BATTERY_STATUS_CHARGING -> "Charging"
                BatteryManager.BATTERY_STATUS_FULL -> "Full"
                BatteryManager.BATTERY_STATUS_DISCHARGING -> "Discharging"
                BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "Not charging"
                else -> "Unknown"
            }
        )
    }

    // Android 系統熱狀態
    private fun getThermalInfo(): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return mapOf(
                "available" to false,
                "status" to null,
                "statusText" to "Unsupported"
            )
        }

        val manager = getSystemService(
            Context.POWER_SERVICE
        ) as PowerManager

        val status = manager.currentThermalStatus

        val text = when (status) {
            PowerManager.THERMAL_STATUS_NONE -> "Normal"
            PowerManager.THERMAL_STATUS_LIGHT -> "Light"
            PowerManager.THERMAL_STATUS_MODERATE -> "Moderate"
            PowerManager.THERMAL_STATUS_SEVERE -> "Severe"
            PowerManager.THERMAL_STATUS_CRITICAL -> "Critical"
            PowerManager.THERMAL_STATUS_EMERGENCY -> "Emergency"
            PowerManager.THERMAL_STATUS_SHUTDOWN -> "Shutdown"
            else -> "Unknown"
        }

        return mapOf(
            "available" to true,
            "status" to status,
            "statusText" to text
        )
    }
}
