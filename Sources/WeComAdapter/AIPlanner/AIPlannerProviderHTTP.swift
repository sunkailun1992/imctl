import Foundation

/// Maps one known provider refusal to a stable, non-sensitive error. This
/// inspects the bounded response only in memory; the provider's message body
/// is never attached to an exception, logged, or returned over MQTT.
enum AIPlannerProviderHTTP {
    static func failure(provider: CloudVisionProvider, statusCode: Int,
                        body: Data) -> AIPlannerVisionError {
        guard provider == .gemini, statusCode == 400,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = payload["error"] as? [String: Any],
              error["status"] as? String == "FAILED_PRECONDITION",
              let message = error["message"] as? String,
              message.localizedCaseInsensitiveContains("location is not supported") else {
            return .invalidHTTPStatus
        }
        return .providerRegionUnavailable
    }
}
