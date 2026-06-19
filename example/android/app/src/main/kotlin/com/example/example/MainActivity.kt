package com.example.example

import android.content.Context
import android.content.Intent
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val TAG = "MainActivity"
    private val CHANNEL = "com.sf.mintel.chat.helper/session"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.d(TAG, "configureFlutterEngine called, registering channel: $CHANNEL")

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            Log.d(TAG, "MethodChannel call received: ${call.method}")
            when (call.method) {
                "saveSession" -> {
                    val arguments = call.arguments as? Map<*, *>
                    val sessionId = arguments?.get("sessionId") as? String
                    val token = arguments?.get("token") as? String
                    val endpoint = arguments?.get("endpoint") as? String

                    Log.d(TAG, "saveSession details: sessionId=$sessionId, token=$token, endpoint=$endpoint")
                    if (sessionId != null && token != null && endpoint != null) {
                        saveSessionToSharedPreferences(sessionId, token, endpoint)
                        result.success(null)
                    } else {
                        result.error("INVALID_ARGUMENTS", "Missing sessionId, token or endpoint", null)
                    }
                }

                "clearSession" -> {
                    clearSessionFromSharedPreferences()
                    result.success(null)
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun saveSessionToSharedPreferences(sessionId: String, token: String, endpoint: String) {
        Log.d(TAG, "Saving session to SharedPreferences and starting service")
        val sharedPref = getSharedPreferences("SF_CHAT_PREFS", Context.MODE_PRIVATE)
        with(sharedPref.edit()) {
            putString("session_id", sessionId)
            putString("token", token)
            putString("endpoint", endpoint)
            apply()
        }

        // Start the background cleanup service to handle potential task removal (force close)
        val intent = Intent(this, ChatCleanupService::class.java)
        startService(intent)
    }

    private fun clearSessionFromSharedPreferences() {
        Log.d(TAG, "Clearing session from SharedPreferences and stopping service")
        val sharedPref = getSharedPreferences("SF_CHAT_PREFS", Context.MODE_PRIVATE)
        with(sharedPref.edit()) {
            remove("session_id")
            remove("token")
            remove("endpoint")
            apply()
        }

        // Stop the service as the session has been cleanly ended
        val intent = Intent(this, ChatCleanupService::class.java)
        stopService(intent)
    }
}
