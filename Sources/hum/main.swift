import AppKit
import Darwin
import Foundation
import HumPlayer
import HumPlex
import HumTUI

private func runBrowser(demo: Bool = false) -> Never {
    guard Terminal.isAttachedToTTY else {
        CLI.failure("stdin/stdout is not a terminal — hum needs one to draw its UI.")
        exit(1)
    }

    let preferences = Preferences.load()
    // Demo mode never authenticates, so it works on a machine that has never
    // seen a Plex account.
    let token: String
    if demo {
        token = "demo"
    } else if let resolved = CLI.ensureToken(preferences: preferences) {
        token = resolved
    } else {
        exit(1)
    }

    let app = HumApp(preferences: preferences, token: token, demoMode: demo)
    let terminal = Terminal()
    // Installed before raw mode so a crash or a SIGTERM still hands the terminal
    // back in a usable state.
    Terminal.installRestoreHandlers()

    let artwork = ArtworkLoader(
        fetch: app.artworkFetcher(),
        onFetched: { [events = app.events] source, data in
            events.post(.artworkFetched(source: source, data: data))
        },
        onDecoded: { [events = app.events] source, width, height, image in
            events.post(
                .artworkLoaded(source: source, width: width, height: height, image: image)
            )
        }
    )
    let browser = BrowserScreen(app: app, terminal: terminal, artwork: artwork)

    // The main thread belongs to AppKit: MPRemoteCommandCenter (media keys),
    // MPNowPlayingInfoCenter, AVPlayer and Metal all want a main run loop. The
    // TUI therefore gets its own thread.
    //
    // `.accessory` keeps hum out of the Dock and the ⌘-Tab switcher while still
    // allowing a window — it is a terminal program that happens to be able to
    // open one.
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    let uiThread = Thread {
        browser.run()
        // Demo audio is generated into the temp directory; a few megabytes a
        // track is not much, but it is ours to tidy up.
        if demo { DemoAudio.cleanUp() }
        exit(0)
    }
    uiThread.name = "hum.ui"
    uiThread.stackSize = 4 << 20
    uiThread.start()

    application.run()
    // NSApplication.run() does not return in normal operation; `atexit` handles
    // the restore if it ever does.
    exit(0)
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case nil, "browse", "play":
    runBrowser()

case "demo":
    runBrowser(demo: true)

case "login":
    if arguments.dropFirst().first == "--token" {
        exit(CLI.loginWithToken(preferences: Preferences.load()))
    }
    let token = CLI.login(preferences: Preferences.load())
    exit(token == nil ? 1 : 0)

case "logout":
    CLI.logout()
    exit(0)

case "token":
    // Writes the token to stdout so it can be carried somewhere the keychain
    // cannot be written — a user with no desktop session, where a keychain
    // write cannot be authorized. A secret on stdout, so it is only ever this
    // explicit subcommand and never part of other output.
    exit(CLI.printToken())

case "artwork":
    exit(Diagnostics.dumpArtwork(
        preferences: Preferences.load(),
        query: arguments.dropFirst().joined(separator: " ")
    ))

case "lyrics":
    exit(Diagnostics.dumpLyrics(
        preferences: Preferences.load(),
        query: arguments.dropFirst().joined(separator: " ")
    ))

case "servers":
    CLI.listServers(preferences: Preferences.load())
    exit(0)

case "version", "--version", "-v":
    // The GPL asks that interactive programs carry a short notice. A CLI's
    // `--version` is where that conventionally goes; the first line is kept
    // machine-readable because the Homebrew formula's test asserts on it.
    print("hum \(humVersion)")
    print("GPL-3.0-or-later. This program comes with ABSOLUTELY NO WARRANTY.")
    exit(0)

case "help", "--help", "-h":
    CLI.usage()
    exit(0)

case let other:
    CLI.failure("unknown command “\(other ?? "")” — try `hum help`")
    exit(64)  // EX_USAGE
}
