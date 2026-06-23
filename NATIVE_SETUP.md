# Native Setup Guide for Salesforce Session Cleanup

This guide describes how to configure the native iOS and Android parts of your main application (Runner) to intercept the `MethodChannel` calls from `SalesforceChatHelper` and handle Salesforce session termination when the app is force-closed (killed) or backgrounded.

---

## 1. Flutter side configuration (Done)
`SalesforceChatHelper` is already configured to emit session credentials via the MethodChannel `com.sf.mintel.chat.helper/session`:
* **Method**: `saveSession` -> sends `{'sessionId': ..., 'token': ..., 'endpoint': ...}`
* **Method**: `clearSession` -> clears native credentials storage.

---

## 2. Android Native Setup (Kotlin)

### Step 2.1: Implement MainActivity.kt
Register the MethodChannel inside your `MainActivity.kt` to listen for the `saveSession` and `clearSession` events, storing credentials in `SharedPreferences`.

```kotlin
package com.example.endchat // Replace with your package name

import android.content.Context
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.sf.mintel.chat.helper/session"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveSession" -> {
                    val arguments = call.arguments as? Map<*, *>
                    val sessionId = arguments?.get("sessionId") as? String
                    val token = arguments?.get("token") as? String
                    val endpoint = arguments?.get("endpoint") as? String
                    
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
```

### Step 2.2: Create the Background Service (`ChatCleanupService.kt`)
Create a background service that overrides `onTaskRemoved`. This callback is invoked when the user swipes the app away from the recent apps screen (Force Close).

```kotlin
package com.example.endchat // Replace with your package name

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

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
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
                    // Clear the session details to prevent double-cleaning
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
```

### Step 2.3: Register Service and Start it in Main App
1. Register `ChatCleanupService` in your `android/app/src/main/AndroidManifest.xml` (inside the `<application>` tag):
   ```xml
   <service android:name=".ChatCleanupService" android:stopWithTask="false" />
   ```
2. Start the service inside `MainActivity.kt` right after saving session info, or when your app initializes:
   ```kotlin
   // Inside saveSessionToSharedPreferences or onCreate
   val intent = Intent(this, ChatCleanupService::class.java)
   startService(intent)
   ```

---

## 3. iOS Native Setup (Swift)

On iOS, we use `UserDefaults` to save the active session. When `applicationWillTerminate` is triggered, we send a synchronous HTTP request to delete the session before the app is killed.

> [!IMPORTANT]
> Flutter now defaults to the `UIScene` lifecycle (as of Flutter 3.41+). Per Apple's requirement and Flutter's [UISceneDelegate migration guide](https://docs.flutter.dev/release/breaking-changes/uiscenedelegate), UI-related logic (such as `MethodChannel` handlers) must be placed in `SceneDelegate`, while `AppDelegate` handles process-level events only.

### Step 3.1: Implement AppDelegate.swift

Handles process-level events: crash reporting, plugin registration, and session cleanup on app termination.
**Do not** register the `MethodChannel` here — that belongs in `SceneDelegate`.

```swift
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        setupCrashReporting()
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    }

    override func applicationWillTerminate(_ application: UIApplication) {
        let defaults = UserDefaults.standard
        guard let sessionId = defaults.string(forKey: "sf_session_id"),
              let token = defaults.string(forKey: "sf_token"),
              let endpointString = defaults.string(forKey: "sf_endpoint"),
              let url = URL(string: endpointString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let json: [String: Any] = [
            "conversationId": sessionId,
            "token": token,
            "activity": "delete",
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: json) else { return }
        request.httpBody = jsonData

        let semaphore = DispatchSemaphore(value: 0)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 2.5

        let session = URLSession(configuration: config)
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                NSLog("Salesforce session cleanup error: \(error.localizedDescription)")
            } else if let httpResponse = response as? HTTPURLResponse {
                NSLog("Salesforce session cleanup response code: \(httpResponse.statusCode)")
            }
            semaphore.signal()
        }
        task.resume()

        _ = semaphore.wait(timeout: .now() + 2.5)

        defaults.removeObject(forKey: "sf_session_id")
        defaults.removeObject(forKey: "sf_token")
        defaults.removeObject(forKey: "sf_endpoint")
    }
}
```

### Step 3.2: Implement SceneDelegate.swift

Handles UI-level communication: registers the `MethodChannel` to receive `saveSession` and `clearSession` calls from Flutter.

```swift
import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
    private let channelName = "com.sf.mintel.chat.helper/session"

    override func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        super.scene(scene, willConnectTo: session, options: connectionOptions)

        if let controller = window?.rootViewController as? FlutterViewController {
            let channel = FlutterMethodChannel(name: channelName, binaryMessenger: controller.binaryMessenger)
            channel.setMethodCallHandler { [weak self] (call, result) in
                if call.method == "saveSession" {
                    if let args = call.arguments as? [String: Any],
                       let sessionId = args["sessionId"] as? String,
                       let token = args["token"] as? String,
                       let endpoint = args["endpoint"] as? String
                    {
                        self?.saveSession(sessionId: sessionId, token: token, endpoint: endpoint)
                        result(nil)
                    } else {
                        result(FlutterError(code: "INVALID_ARGUMENTS", message: "Arguments error", details: nil))
                    }
                } else if call.method == "clearSession" {
                    self?.clearSession()
                    result(nil)
                } else {
                    result(FlutterMethodNotImplemented)
                }
            }
        }
    }

    private func saveSession(sessionId: String, token: String, endpoint: String) {
        let defaults = UserDefaults.standard
        defaults.set(sessionId, forKey: "sf_session_id")
        defaults.set(token, forKey: "sf_token")
        defaults.set(endpoint, forKey: "sf_endpoint")
    }

    private func clearSession() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "sf_session_id")
        defaults.removeObject(forKey: "sf_token")
        defaults.removeObject(forKey: "sf_endpoint")
    }
}
```
