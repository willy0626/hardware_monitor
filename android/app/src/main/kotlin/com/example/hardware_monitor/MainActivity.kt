
package com.example.hardware_monitor

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
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

import java.io.File
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {

    private val CHANNEL = "hardware_monitor/native"

    private var lastCpuTimeMs = -1L
    private var lastWallTimeMs = -1L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {
                "getHardwareInfo" -> {
                    thread {
                        try {
                            val data = getHardwareInfo()

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
    private fun getHardwareInfo(): Map<String, Any?> {
        return mapOf(
            "device" to safeHardwareRead { getDeviceInfo() },
            "cpu" to safeHardwareRead { getCpuInfo() },
            "ram" to safeHardwareRead { getRamInfo() },
            "gpu" to safeHardwareRead { getGpuInfo() },
            "battery" to safeHardwareRead { getBatteryInfo() },
            "thermal" to safeHardwareRead { getThermalInfo() }
        )
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
        val frequencies = mutableListOf<Int>()

        for (i in 0 until cores) {
            try {
                val file = File(
                    "/sys/devices/system/cpu/cpu$i/cpufreq/scaling_cur_freq"
                )

                if (file.canRead()) {
                    val khz = file.readText().trim().toInt()
                    frequencies.add(khz / 1000)
                }
            } catch (_: Exception) {
                // Android 可能限制讀取核心頻率
            }
        }

        return mapOf(
            "cores" to cores,
            "usage" to usage,
            "usageScope" to "App process",
            "frequenciesMHz" to frequencies,
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

    // GPU 資訊
    private fun getGpuInfo(): Map<String, Any?> {
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
        )
    }

    // 電池資訊
    private fun getBatteryInfo(): Map<String, Any?> {
        val intent = registerReceiver(
            null,
            IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        )

        val level = intent?.getIntExtra(
            BatteryManager.EXTRA_LEVEL, -1
        ) ?: -1

        val scale = intent?.getIntExtra(
            BatteryManager.EXTRA_SCALE, -1
        ) ?: -1

        val temperature = intent?.getIntExtra(
            BatteryManager.EXTRA_TEMPERATURE, -1
        ) ?: -1

        val status = intent?.getIntExtra(
            BatteryManager.EXTRA_STATUS, -1
        ) ?: -1

        val batteryLevel = if (scale > 0 && level >= 0) {
            level * 100 / scale
        } else {
            -1
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
