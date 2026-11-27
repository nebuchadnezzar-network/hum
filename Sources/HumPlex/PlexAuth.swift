import Foundation

/// Identifies hum to plex.tv and to servers. The client identifier must be stable
/// across launches or the account accrues a new "device" on every run.
public struct DeviceInfo: Sendable {
    public let product: String
    public let version: String
    public let platform: String
    public let platformVersion: String
    public let device: String
    public let deviceName: String
    public let clientIdentifier: String

    public let model: String

    public init(clientIdentifier: String, version: String = humVersion) {
        self.product = "hum"
        self.version = version
        self.platform = "macOS"
        // `operatingSystemVersionString` is a sentence — "Version 15.7.3 (Build
        // 24G419)" — not a version. The server logged it verbatim while failing
        // to identify the client.
        let os = ProcessInfo.processInfo.operatingSystemVersion
        self.platformVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        self.device = "Mac"
        self.deviceName = Host.current().localizedName ?? "Mac"
        self.model = Self.hardwareModel()
        self.clientIdentifier = clientIdentifier
    }

    /// `hw.model`, e.g. `Mac14,9`.
    ///
    /// This header used to be the constant `"hosted"`, which is what Plex *Web*
    /// sends — a browser-hosted client. Pasted onto a native binary it produced
    /// a combination no real device has, and the server said so on every
    /// request made during playback:
    ///
    /// ```
    /// ERROR - Unable to find client profile for device; platform=macOS,
    ///         platformVersion=Version 15.7.3 (Build 24G419),
    ///         device=macOS, model=hosted
    /// ```
    ///
    /// The specification wants "a potentially less friendly identifier for the
    /// device model" here, example `4200X`. That is the hardware model.
    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "Mac" }
        return String(cString: bytes)
    }

    /// The `X-Plex-*` headers every Plex endpoint expects.
    public var headers: [String: String] {
        [
            "X-Plex-Product": product,
            "X-Plex-Version": version,
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Platform": platform,
            "X-Plex-Platform-Version": platformVersion,
            "X-Plex-Device": device,
            "X-Plex-Device-Name": deviceName,
            "X-Plex-Model": model,
            "Accept": "application/json",
        ]
    }
}

public let humVersion = "0.1.11"

public enum PlexError: Error, LocalizedError {
    case badResponse(status: Int, body: String)
    case decoding(String)
    case noServerFound
    case notAuthenticated
    case authorizationTimedOut
    case noPlayableMedia(String)

    public var errorDescription: String? {
        switch self {
        case .badResponse(let status, let body):
            let trimmed = body.prefix(200)
            return "Plex returned HTTP \(status)\(trimmed.isEmpty ? "" : ": \(trimmed)")"
        case .decoding(let detail):
            return "Could not read Plex's response: \(detail)"
        case .noServerFound:
            return "No reachable Plex Media Server on this account."
        case .notAuthenticated:
            return "Not signed in to Plex. Run `hum login`."
        case .authorizationTimedOut:
            return "Timed out waiting for the browser sign-in to finish."
        case .noPlayableMedia(let title):
            return "No playable media for “\(title)”."
        }
    }
}

/// plex.tv PIN-based sign-in: ask for a PIN, send the user to app.plex.tv with it,
/// then poll until the PIN comes back carrying a token. No password ever touches hum.
public struct PlexAuth: Sendable {
    public struct PIN: Sendable {
        public let id: Int
        public let code: String
        public let authURL: URL
    }

    private struct PINResponse: Decodable {
        var id: Int
        var code: String
        var authToken: String?
        var expiresIn: Int?
    }

    private struct AccountResponse: Decodable {
        var username: String?
        var email: String?
        var title: String?
    }

    public let device: DeviceInfo
    private let session: URLSession

    public init(device: DeviceInfo, session: URLSession = PlexSession.shared) {
        self.device = device
        self.session = session
    }

    public func requestPIN() async throws -> PIN {
        var request = URLRequest(url: URL(string: "https://plex.tv/api/v2/pins")!)
        request.httpMethod = "POST"
        request.httpBody = Data("strong=true".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (key, value) in device.headers { request.setValue(value, forHTTPHeaderField: key) }

        let response: PINResponse = try await send(request)

        // The auth page reads its parameters from the URL fragment, so these are
        // percent-encoded by hand rather than by URLComponents (which would put
        // them in the query string).
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "clientID", value: device.clientIdentifier),
            URLQueryItem(name: "code", value: response.code),
            URLQueryItem(name: "context[device][product]", value: device.product),
            URLQueryItem(name: "context[device][deviceName]", value: device.deviceName),
            URLQueryItem(name: "context[device][platform]", value: device.platform),
        ]
        let fragment = components.percentEncodedQuery ?? ""
        let url = URL(string: "https://app.plex.tv/auth#?\(fragment)")!

        return PIN(id: response.id, code: response.code, authURL: url)
    }

    /// Polls the PIN until it carries a token. Plex PINs live ~15 minutes; the
    /// default deadline is shorter because an unattended terminal shouldn't sit
    /// there forever.
    public func waitForToken(
        pin: PIN,
        pollInterval: Duration = .seconds(2),
        timeout: Duration = .seconds(300)
    ) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()

            var request = URLRequest(url: URL(string: "https://plex.tv/api/v2/pins/\(pin.id)")!)
            for (key, value) in device.headers { request.setValue(value, forHTTPHeaderField: key) }

            let response: PINResponse = try await send(request)
            if let token = response.authToken, !token.isEmpty {
                return token
            }
            try await Task.sleep(for: pollInterval)
        }
        throw PlexError.authorizationTimedOut
    }

    /// Confirms a token works and returns the account name, for the status line.
    public func accountName(token: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://plex.tv/api/v2/user")!)
        for (key, value) in device.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        let response: AccountResponse = try await send(request)
        return response.username ?? response.title ?? response.email
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlexError.badResponse(status: -1, body: "")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PlexError.badResponse(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PlexError.decoding(String(describing: error))
        }
    }
}
