import Foundation
import os.log

public struct UpdateCheckResult: Sendable, Equatable {
    /// Tag as published on GitHub, e.g. "v0.3.0".
    public let tagName: String
    /// Tag with the leading "v" stripped, e.g. "0.3.0".
    public let version: String
    /// Browser URL of the release page on GitHub.
    public let releaseURL: URL

    public init(tagName: String, version: String, releaseURL: URL) {
        self.tagName = tagName
        self.version = version
        self.releaseURL = releaseURL
    }
}

public enum UpdateCheckError: Error, LocalizedError, Sendable {
    case offline
    case rateLimited
    case http(Int)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .offline:           return "Couldn't reach GitHub. Check your network."
        case .rateLimited:       return "GitHub rate limit reached. Try again later."
        case .http(let status):  return "GitHub returned HTTP \(status)."
        case .malformedResponse: return "Couldn't parse the response from GitHub."
        }
    }
}

public enum UpdateChecker {
    public static let repoOwner = "marcoduering"
    public static let repoName  = "MIQ"

    public static var latestReleasePageURL: URL {
        URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest")!
    }

    public static var latestAppDownloadURL: URL {
        URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest/download/MIQ.app.zip")!
    }

    private static let apiURL = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
    private static let logger = Logger(subsystem: "miq.app", category: "updates")

    public static func fetchLatestRelease(session: URLSession = .shared) async throws -> UpdateCheckResult {
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("MIQ-macOS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            logger.error("Update check network failure: \(urlError.localizedDescription, privacy: .public)")
            throw UpdateCheckError.offline
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.malformedResponse
        }
        switch http.statusCode {
        case 200:
            break
        case 403, 429:
            throw UpdateCheckError.rateLimited
        default:
            throw UpdateCheckError.http(http.statusCode)
        }

        struct Payload: Decodable {
            let tag_name: String
            let html_url: String
            let draft: Bool?
            let prerelease: Bool?
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw UpdateCheckError.malformedResponse
        }

        guard let url = URL(string: payload.html_url) else {
            throw UpdateCheckError.malformedResponse
        }
        return UpdateCheckResult(
            tagName: payload.tag_name,
            version: stripLeadingV(payload.tag_name),
            releaseURL: url
        )
    }

    /// Returns true when `latest` is strictly newer than `current`. Both inputs
    /// may include a leading "v"; non-numeric or empty inputs return false so
    /// a parsing glitch never falsely advertises an update.
    public static func isNewer(latest: String, than current: String) -> Bool {
        let l = parseVersion(latest)
        let c = parseVersion(current)
        guard !l.isEmpty, !c.isEmpty else { return false }
        let count = max(l.count, c.count)
        for i in 0..<count {
            let a = i < l.count ? l[i] : 0
            let b = i < c.count ? c[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func parseVersion(_ raw: String) -> [Int] {
        let stripped = stripLeadingV(raw)
        // Drop anything past a pre-release/build suffix like "1.2.3-rc.1".
        let core = stripped.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? stripped
        let parts = core.split(separator: ".").map(String.init)
        var out: [Int] = []
        for p in parts {
            guard let n = Int(p), n >= 0 else { return [] }
            out.append(n)
        }
        return out
    }

    private static func stripLeadingV(_ s: String) -> String {
        guard let first = s.first, first == "v" || first == "V" else { return s }
        return String(s.dropFirst())
    }
}
