package com.gpscontrolec.gps_sms_gateway

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val controlChannel = "gps_gateway/control"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, controlChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startService" -> {
                        val apiBase  = call.argument<String>("api_base")  ?: ""
                        val apiKey   = call.argument<String>("api_key")   ?: ""
                        val pollSecs = call.argument<Int>("poll_secs")?.toLong() ?: 15L

                        getSharedPreferences("gateway_config", MODE_PRIVATE).edit()
                            .putString("api_base", apiBase)
                            .putString("api_key", apiKey)
                            .putLong("poll_secs", pollSecs)
                            .apply()

                        val intent = Intent(this, GatewayService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    }
                    "stopService" -> {
                        stopService(Intent(this, GatewayService::class.java))
                        result.success(true)
                    }
                    "isRunning" -> {
                        result.success(isServiceRunning())
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun isServiceRunning(): Boolean {
        val manager = getSystemService(ACTIVITY_SERVICE) as android.app.ActivityManager
        @Suppress("DEPRECATION")
        return manager.getRunningServices(Int.MAX_VALUE)
            .any { it.service.className == GatewayService::class.java.name }
    }
}
