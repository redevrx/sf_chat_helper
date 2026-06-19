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
        defaults.synchronize()
    }

    private func clearSession() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "sf_session_id")
        defaults.removeObject(forKey: "sf_token")
        defaults.removeObject(forKey: "sf_endpoint")
        defaults.synchronize()
    }
}
