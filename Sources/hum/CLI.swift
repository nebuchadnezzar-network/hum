import AppKit
import Foundation
import HumPlex
import HumTUI

/// Plain-stdout subcommands: everything that happens before (or instead of) the
/// full-screen UI. Deliberately synchronous — these run on the main thread before
/// the AppKit run loop starts, so they bridge async work with a semaphore rather
/// than making `main` itself async.
enum CLI {
    static let keychainAccount = "authToken"

    // MARK: - ANSI helpers
    //
    // These write directly rather than going through `Screen`: there is no grid
    // yet, we are still in the user's normal scrollback.

    /// Matches whatever the terminal can render, and goes quiet entirely when
    /// stdout is a pipe — so `hum help | less` stays readable, and Terminal.app
    /// gets indexed colour rather than a truecolor sequence it would show green.
    private static let depth = ColorDepth.detected

    private static func escape(_ color: Color, bold: Bool = false) -> String {
        guard depth != .none else { return "" }
        let parameters = (bold ? ["1"] : []) + color.sgrParameters(foreground: true, depth: depth)
        return "\u{1B}[" + parameters.joined(separator: ";") + "m"
    }
    private static var reset: String { depth == .none ? "" : "\u{1B}[0m" }

    static func printBanner() {
        for line in splashBanner {
            var rendered = ""
            var current: Color?
            for character in line {
                // One escape per colour run, not per character.
                let color = (character == ")" || character == ">") ? Palette.amber : Palette.fog
                if color != current {
                    rendered += escape(color)
                    current = color
                }
                rendered.append(character)
            }
            print(rendered + reset)
        }
        print("")
    }

    static func note(_ message: String) {
        print(escape(Palette.mute) + message + reset)
    }

    static func highlight(_ message: String) {
        print(escape(Palette.amber, bold: true) + message + reset)
    }

    static func failure(_ message: String) {
        FileHandle.standardError.write(Data((escape(Palette.amber) + "hum: " + message + reset + "\n").utf8))
    }

    // MARK: - Commands

    static func usage() {
        printBanner()
        print("""
        \(escape(Palette.fog))hum\(reset) — a tiny Plex audio player for your terminal

        \(escape(Palette.mute))usage:\(reset)
          hum                 browse and play (signs in on first run)
          hum login           sign in to Plex in your browser
          hum logout          forget the stored token
          hum token           print the stored token (for HUM_PLEX_TOKEN)
          hum login --token   read a token from stdin, skipping the browser
          hum servers         list reachable Plex servers on the account
          hum demo            browse a fake library (no Plex account needed)
          hum artwork [query] dump the cover-art pipeline to ~/hum-artwork-report
          hum lyrics  [query] check what the server holds for lyrics
          hum tags            check which tag facets this server supports
          hum stream  [query] find out why a track will not play
          hum version         print the version
          hum help            this text

        \(escape(Palette.mute))in the browser:\(reset) press \(escape(Palette.amber))?\(reset) for the full key list.
        """)
    }

    /// Returns a usable token, signing in interactively if needed.
    ///
    /// `HUM_PLEX_TOKEN` wins when set, for headless runs and for poking at the UI
    /// without touching the keychain.
    static func ensureToken(preferences: Preferences) -> String? {
        if let token = ProcessInfo.processInfo.environment["HUM_PLEX_TOKEN"], !token.isEmpty {
            return token
        }
        switch Keychain.lookup(account: keychainAccount) {
        case .found(let token):
            return token

        case .absent:
            note("No stored Plex token — signing in.")
            print("")
            return login(preferences: preferences)

        case .refused(let status):
            // A token is there; this build is not allowed to read it. Signing
            // in again would work, but it replaces something that already
            // exists, so say what happened instead of pretending it is absent.
            note("A Plex token is stored, but this build of hum cannot read it (OSStatus \(status)).")
            print("""
              The keychain entry is tied to the signing identity of the hum that
              created it. A separately built or installed copy is a different
              caller, so macOS refuses it.

                • Allow access if prompted, and choose Always Allow.
                • Or run `hum logout` and sign in again from this copy.
                • Installed more than one hum? They each ask once:
                    \(Bundle.main.bundlePath)

              """)
            return login(preferences: preferences)

        case .failed(let status):
            note("Could not read the keychain (OSStatus \(status)) — signing in.")
            print("")
            return login(preferences: preferences)
        }
    }

    /// Stores a token read from stdin, skipping the browser entirely.
    ///
    /// For a machine where the browser flow will not complete — the wrong Plex
    /// account signed in, a blocked auth page, a clock too far off for the PIN
    /// — and for piping between machines:
    ///
    ///     hum token | ssh other-mac hum login --token
    ///
    /// Stdin rather than an argument: a token on the command line is a secret
    /// in shell history and in `ps`.
    static func loginWithToken(preferences: Preferences) -> Int32 {
        note("Paste the Plex token, then press ⌃D:")
        guard let raw = readLine(strippingNewline: true)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            failure("no token given")
            return 1
        }

        // Check it before storing it, or the first sign of a bad paste is the
        // browser failing to load a library later.
        let auth = PlexAuth(device: DeviceInfo(clientIdentifier: preferences.clientIdentifier))
        guard let name = (try? blocking { try await auth.accountName(token: raw) }) ?? nil else {
            failure("Plex did not accept that token")
            return 1
        }

        do {
            try Keychain.set(raw, account: keychainAccount)
        } catch {
            failure("token is valid, but could not be saved: \(error.localizedDescription)")
            note("Use it for one session with: export HUM_PLEX_TOKEN=…")
            return 1
        }
        highlight("Signed in as \(name). Token saved to your keychain.")
        return 0
    }

    /// Prints the stored token, for carrying to an environment that cannot
    /// read or write a keychain.
    ///
    /// Nothing is echoed but the token itself, so `export
    /// HUM_PLEX_TOKEN=$(hum token)` works.
    static func printToken() -> Int32 {
        switch Keychain.lookup(account: keychainAccount) {
        case .found(let token):
            print(token)
            return 0
        case .absent:
            failure("no stored token — run `hum login` first")
            return 1
        case .refused(let status):
            failure("a token is stored but this build cannot read it (OSStatus \(status))")
            return 1
        case .failed(let status):
            failure("could not read the keychain (OSStatus \(status))")
            return 1
        }
    }

    @discardableResult
    static func login(preferences: Preferences) -> String? {
        let auth = PlexAuth(device: DeviceInfo(clientIdentifier: preferences.clientIdentifier))

        let pin: PlexAuth.PIN
        do {
            pin = try blocking { try await auth.requestPIN() }
        } catch {
            failure("could not start sign-in: \(error.localizedDescription)")
            return nil
        }

        // Shown because this is the one thing in the link that varies by
        // machine, and a blank or duplicated one is answered by Plex with a
        // generic failure *after* sign-in — which looks like an account
        // problem rather than a bad link.
        note("Signing in as device \(preferences.clientIdentifier)")
        highlight("Opening your browser to sign in to Plex…")
        note("If it doesn't open, visit:")
        print("  \(escape(Palette.fog))\(pin.authURL.absoluteString)\(reset)")
        note("Linking code: \(pin.code)")
        print("")

        NSWorkspace.shared.open(pin.authURL)

        // A spinner on a background thread: the poll blocks the main thread, and
        // a silent five-minute wait looks like a hang.
        let spinnerActive = SpinnerFlag()
        startSpinner(flag: spinnerActive, message: "waiting for sign-in")

        defer {
            spinnerActive.stop()
            // Clear the spinner line.
            print("\r\u{1B}[2K", terminator: "")
            fflush(stdout)
        }

        let token: String
        do {
            token = try blocking { try await auth.waitForToken(pin: pin) }
        } catch {
            failure(error.localizedDescription)
            return nil
        }

        do {
            try Keychain.set(token, account: keychainAccount)
        } catch {
            // Signed in, so this session works — it just will not be
            // remembered. Say that, and name the way out: a keychain that
            // cannot be written is usually a user with no GUI session to show
            // the authorization dialog in, which no amount of retrying fixes.
            failure("signed in, but could not save the token: \(error.localizedDescription)")
            print("""
              hum works for this session and will ask again next time.

              A keychain write needs a desktop session to authorize it, so this
              fails for a user reached with `su` or `sudo -u`. Either sign in to
              that user's own desktop session, or carry the token in the
              environment instead:

                export HUM_PLEX_TOKEN=…

              `hum token` prints the stored token from a copy that can read it.

              """)
            return token
        }

        spinnerActive.stop()
        print("\r\u{1B}[2K", terminator: "")

        let name = (try? blocking { try await auth.accountName(token: token) }) ?? nil
        highlight("Signed in\(name.map { " as \($0)" } ?? ""). Token saved to your keychain.")
        return token
    }

    static func logout() {
        if Keychain.delete(account: keychainAccount) {
            highlight("Forgot the stored Plex token.")
        } else {
            note("No stored token to forget.")
        }
    }

    static func listServers(preferences: Preferences) {
        guard let token = Keychain.get(account: keychainAccount) else {
            failure("not signed in — run `hum login`")
            return
        }
        let client = PlexClient(
            device: DeviceInfo(clientIdentifier: preferences.clientIdentifier),
            token: token
        )
        do {
            let servers = try blocking { try await client.discoverServers() }
            for server in servers {
                let route = server.isRelay ? "relay" : (server.isLocal ? "local" : "remote")
                print("\(escape(Palette.amber))\(server.name)\(reset)  \(escape(Palette.mute))\(route)\(reset)")
                print("  \(server.baseURL.absoluteString)")
            }
        } catch {
            failure(error.localizedDescription)
        }
    }

    // MARK: - Async bridging

    /// Runs an async operation to completion on the current thread.
    ///
    /// Safe here because every caller runs before the AppKit run loop starts and
    /// none of the work being awaited needs the main thread.
    static func blocking<T>(_ body: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task {
            do {
                box.value = .success(try await body())
            } catch {
                box.value = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch box.value {
        case .success(let value): return value
        case .failure(let error): throw error
        case .none: throw PlexError.badResponse(status: -1, body: "no result")
        }
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: Result<T, Error>?
    }

    private final class SpinnerFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        var isRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            return running
        }
        func stop() {
            lock.lock()
            running = false
            lock.unlock()
        }
    }

    private static func startSpinner(flag: SpinnerFlag, message: String) {
        // The ")))" wave from the branding, animated.
        let frames = [">    ", ">)   ", ">))  ", ">))) ", " ))) ", "  )) ", "   ) "]
        let thread = Thread {
            var index = 0
            while flag.isRunning {
                let frame = frames[index % frames.count]
                print(
                    "\r\(escape(Palette.amber))\(frame)\(reset) \(escape(Palette.mute))\(message)…\(reset)",
                    terminator: ""
                )
                fflush(stdout)
                index += 1
                Thread.sleep(forTimeInterval: 0.12)
            }
        }
        thread.name = "hum.spinner"
        thread.start()
    }
}
