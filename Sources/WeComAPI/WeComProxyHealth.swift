import ControlCore
import Foundation

/// B52 readiness: `GET <baseURL>/healthz` of the token proxy. No token is sent (the endpoint is outside
/// `/wecom/`), the answer's corpId is never read out, and a redirect counts as a failure.
public enum WeComProxyHealth {
    public static func probe(settingsURL: URL, timeout: TimeInterval = 10, session: URLSession? = nil) -> ReadinessProbeResult {
        let started = Date()
        guard let settings = try? WeComProxySettings.load(from: settingsURL) else { return .failure("config", latencyMs: 0) }
        let url = settings.normalizedBaseURL.appendingPathComponent("healthz")
        guard url.scheme == "https" || url.scheme == "http" else { return .failure("config", latencyMs: 0) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        let live = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            return URLSession(configuration: configuration)
        }()
        final class Box: @unchecked Sendable { var data: Data?; var response: URLResponse?; var error: Error? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let task = live.dataTask(with: request) { data, response, error in
            box.data = data; box.response = response; box.error = error
            done.signal()
        }
        task.resume()
        guard done.wait(timeout: .now() + timeout + 1) == .success else {
            task.cancel()
            return .failure("timeout", latencyMs: ReadinessProbeResult.elapsedMs(since: started))
        }
        let latency = ReadinessProbeResult.elapsedMs(since: started)
        if let error = box.error { return .failure((error as? URLError)?.code == .timedOut ? "timeout" : "network", latencyMs: latency) }
        guard let http = box.response as? HTTPURLResponse else { return .failure("response", latencyMs: latency) }
        guard http.url == url else { return .failure("redirect", latencyMs: latency) }
        guard http.statusCode == 200 else { return .failure(http.statusCode >= 500 ? "http5xx" : "http4xx", latencyMs: latency) }
        guard let data = box.data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["status"] as? String == "ok" else { return .failure("response", latencyMs: latency) }
        return .success(latencyMs: latency)
    }
}
