import Foundation

/// One HTTP request, as a plugin describes it.
public struct FetchRequest: Sendable {
    public var url: String
    public var method: String = "GET"
    public var headers: [String: String] = [:]
    public var body: String?
    public var timeout: Double = 15

    public init(url: String) { self.url = url }

    /// From the string pairs a Lua table arrives as. Headers come in as `header.Name`,
    /// because a command's arguments are flat.
    public init(url: String, options: [String: String]) {
        self.init(url: url)
        method = options["method"]?.uppercased() ?? "GET"
        body = options["body"]
        if let value = options["timeout"], let seconds = Double(value), seconds > 0 {
            timeout = seconds
        }
        for (key, value) in options where key.hasPrefix("header.") {
            headers[String(key.dropFirst("header.".count))] = value
        }
    }
}

/// The one place the app talks to the network, and it only ever does so because a plugin
/// asked. Nothing is fetched on the app's own initiative.
///
/// Bodies are capped and decoded as text: plugins put text on screen, and an unbounded
/// download into a menu bar app is nobody's idea of a feature.
public enum Fetch {
    public static let maximumBody = 4 * 1024 * 1024

    /// Completion runs on the main queue: everything it can touch is main-actor state.
    public static func send(_ request: FetchRequest,
                            completion: @escaping @Sendable (String?, Int, String?) -> Void) {
        guard let url = URL(string: request.url), url.scheme == "https" || url.scheme == "http" else {
            DispatchQueue.main.async { completion(nil, 0, "not an http(s) url: \(request.url)") }
            return
        }

        var urlRequest = URLRequest(url: url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body.map { Data($0.utf8) }
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }

        URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = data.map { String(decoding: $0.prefix(maximumBody), as: UTF8.self) }
            let message = error?.localizedDescription
            DispatchQueue.main.async { completion(text, status, message) }
        }.resume()
    }
}
