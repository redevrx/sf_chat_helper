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
            let url = URL(string: endpointString)
        else { return }

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

        // Use a semaphore to make the call synchronous during app termination.
        // iOS cancels background URLSession tasks when the user force-quits the app (swipes away),
        // so a synchronous foreground network request with a short timeout is much more reliable.
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

        // Wait for the request to complete (up to 2.5 seconds)
        _ = semaphore.wait(timeout: .now() + 2.5)

        defaults.removeObject(forKey: "sf_session_id")
        defaults.removeObject(forKey: "sf_token")
        defaults.removeObject(forKey: "sf_endpoint")
    }
}

func mySignalHandler(signal: Int32) {
    NSLog("💥 CRASH: Signal \(signal) received")
    for symbol in Thread.callStackSymbols {
        NSLog("💥 \(symbol)")
    }
    exit(signal)
}

func setupCrashReporting() {
    NSSetUncaughtExceptionHandler { exception in
        NSLog("💥 CRASH: Uncaught Exception: \(exception)")
        NSLog("💥 Stack Trace:\n\(exception.callStackSymbols.joined(separator: "\n"))")
    }

    signal(SIGABRT, mySignalHandler)
    signal(SIGILL, mySignalHandler)
    signal(SIGSEGV, mySignalHandler)
    signal(SIGFPE, mySignalHandler)
    signal(SIGBUS, mySignalHandler)
}
