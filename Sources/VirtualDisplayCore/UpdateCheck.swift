import Foundation

/// Is there a newer release than the one running? Asked only when someone presses the
/// button in About; nothing here runs on a timer.
///
/// It reports and links, it does not install. Updating is `brew upgrade` or a download,
/// both of which already work and neither of which needs code in a menu bar app.
public enum UpdateCheck {
    public static let repository = "rapatao/virtual-display"
    static let latestReleaseURL = "https://api.github.com/repos/\(repository)/releases/latest"
    public static let releasesPage = "https://github.com/\(repository)/releases"

    public struct Release: Equatable {
        /// The tag with its `v` kept, because that is what the release is called.
        public let version: String
        public let page: String
    }

    /// `0.0.0` for a build run straight out of `.build`, which has no Info.plist and so
    /// reads as "anything published is newer". Honest, and only ever seen by developers.
    public static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// `nil` when the running build is current. Completion runs on the main queue.
    public static func latest(completion: @escaping @Sendable (Result<Release?, Error>) -> Void) {
        var request = FetchRequest(url: latestReleaseURL)
        // Documented as required by the GitHub API; without it the response shape is
        // whatever the default version happens to be that year.
        request.headers["Accept"] = "application/vnd.github+json"
        let current = currentVersion

        Fetch.send(request) { body, status, error in
            if let error {
                return completion(.failure(Failure(error)))
            }
            guard status == 200 else {
                return completion(.failure(Failure("GitHub replied \(status).")))
            }
            guard let body, let release = parse(body) else {
                return completion(.failure(Failure("Could not read the release list.")))
            }
            completion(.success(isNewer(release.version, than: current) ? release : nil))
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Two fields out of a response with fifty of them; a Codable type would be more
    /// code and no more correct.
    static func parse(_ body: String) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)),
              let json = object as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return nil }
        return Release(version: tag, page: json["html_url"] as? String ?? releasesPage)
    }

    /// Component-wise, so 1.10 beats 1.9 where a string comparison would not. Missing
    /// components count as zero, so 1.2 and 1.2.0 are the same release. Anything
    /// non-numeric (`v1.2.3-beta`) stops the comparison there rather than guessing at
    /// pre-release ordering.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let left = components(remote), right = components(local)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        var numbers: [Int] = []
        for part in version.drop(while: { !$0.isNumber }).split(separator: ".") {
            guard let number = Int(part) else { break }
            numbers.append(number)
        }
        return numbers
    }
}
