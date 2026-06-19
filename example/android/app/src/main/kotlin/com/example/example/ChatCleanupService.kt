package com.example.example

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.util.Log
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

class ChatCleanupService : Service() {
    private val TAG = "ChatCleanupService"

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "ChatCleanupService onCreate called")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "ChatCleanupService onStartCommand called")
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        Log.d(TAG, "App is being killed / swiped away. Initiating session cleanup...")

        val sharedPref = getSharedPreferences("SF_CHAT_PREFS", Context.MODE_PRIVATE)
        val sessionId = sharedPref.getString("session_id", null)
        val token = sharedPref.getString("token", null)
        val endpoint = sharedPref.getString("endpoint", null)

        if (sessionId != null && token != null && endpoint != null) {
            val t = thread {
                try {
                    sendDeleteRequest(endpoint, sessionId, token)
                } finally {
                    sharedPref.edit().clear().apply()
                }
            }
            try {
                // Block the service's main thread to keep the process alive 
                // until the background network thread finishes (up to 3 seconds)
                t.join(3000)
            } catch (e: InterruptedException) {
                Log.e(TAG, "Cleanup thread interrupted", e)
            }
        }
        stopSelf()
    }

    private fun sendDeleteRequest(endpoint: String, sessionId: String, token: String) {
        var urlConnection: HttpURLConnection? = null
        try {
            val url = URL(endpoint)
            urlConnection = url.openConnection() as HttpURLConnection
            urlConnection.requestMethod = "POST"
            urlConnection.setRequestProperty("Content-Type", "application/json; utf-8")
            urlConnection.doOutput = true

            val jsonInputString = """
                {
                    "conversationId": "$sessionId",
                    "token": "$token",
                    "activity": "delete"
                }
            """.trimIndent()

            Log.d(TAG, "Sending delete request to: $endpoint")
            Log.d(TAG, "Request Body:\n$jsonInputString")

            urlConnection.outputStream.use { os ->
                val input = jsonInputString.toByteArray(charset("utf-8"))
                os.write(input, 0, input.size)
            }

            val responseCode = urlConnection.responseCode
            val responseBody = try {
                val stream = if (responseCode in 200..299) {
                    urlConnection.inputStream
                } else {
                    urlConnection.errorStream
                }
                stream?.bufferedReader()?.use { it.readText() } ?: ""
            } catch (e: Exception) {
                "Error reading response body: ${e.message}"
            }

            Log.d(TAG, "Salesforce delete session response code: $responseCode")
            Log.d(TAG, "Response Body:\n$responseBody")
        } catch (e: Exception) {
            Log.e(TAG, "Error sending Salesforce session cleanup request", e)
        } finally {
            urlConnection?.disconnect()
        }
    }
}
