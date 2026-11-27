#  Homebrew formula for hum. This repository is its own tap:
#
#      brew tap nebuchadnezzar-network/hum https://github.com/nebuchadnezzar-network/hum.git
#      brew trust nebuchadnezzar-network/hum
#      brew install hum
#
#  `brew trust` because Homebrew will not load a formula from a non-official
#  tap until told to — a formula is Ruby it runs during install.
#
#  The two-argument form, because `brew tap user/name` alone requires the
#  repository to be named `homebrew-name`. Homebrew looks in `Formula/`,
#  `HomebrewFormula/`, then the root — so this file is found either way.
#
#  Living here rather than in a separate tap means every release ships the
#  formula alongside it, already pointing at that release's tag. A separate tap
#  would be a second commit to remember, and a window where it advertised a
#  version that was not out yet.
#
#  Why a tap and not homebrew-core: core requires an open-source licence,
#  an immutable upstream tag, and — the one that actually bites — says
#  "a formula whose primary output is a native macOS .app bundle is not
#  eligible". hum's output is a terminal program, but it has to be wrapped
#  in a bundle, because macOS only hands media keys and Now Playing to a
#  process with bundle identity. A tap has none of those rules.
#
#  Why not a cask: casks distribute pre-built apps, which would mean
#  signing and notarising with a paid Developer ID on every release. A
#  formula builds from source on the user's machine, so there is nothing
#  to notarise and nothing to quarantine.
class Hum < Formula
  desc "Terminal Plex music player with GPU-accelerated visualisation"
  homepage "https://github.com/nebuchadnezzar-network/hum"

  # The git-tag form rather than an archive tarball, so there is no sha256 to
  # keep in step. GitHub regenerates `/archive/` tarballs, and their hashes
  # have changed under projects before now; a tag cannot.
  #
  # Add `revision:` to pin the exact commit — homebrew-core requires it; a
  # personal tap does not, and a signed tag is already immutable.
  url "https://github.com/nebuchadnezzar-network/hum.git",
      tag: "v0.1.11"
  # Matches the LICENSE file. "-or-later" is the FSF's own recommended
  # boilerplate ("version 3 ... or (at your option) any later version");
  # change to "GPL-3.0-only" to pin it to exactly version 3.
  license "GPL-3.0-or-later"
  head "https://github.com/nebuchadnezzar-network/hum.git", branch: "main"

  # macOS only: AVFoundation, MPRemoteCommandCenter, Keychain.
  depends_on :macos

  # The minimum version goes in a block. A bare `depends_on :macos` beside a
  # versioned `depends_on macos:` at the top level is disabled; inside a block
  # it is the sanctioned form.
  on_macos do
    # Package.swift declares .macOS(.v14).
    depends_on macos: :sonoma

    # swift-tools-version 6.0 needs the Swift 6 toolchain. Sequoia ships it;
    # Sonoma ships 5.9, so there it needs Xcode 16.
    depends_on xcode: ["16.0", :build] if MacOS.version < :sequoia
  end

  uses_from_macos "swift" => :build, since: :sequoia

  # No external SwiftPM dependencies, so nothing is fetched during the build.
  deny_network_access!

  def install
    system "swift", "build", *std_swift_args

    # The .app wrapper is not decoration. A bare SwiftPM executable has no
    # bundle identity, so macOS never delivers media keys or populates Now
    # Playing — hum plays fine and F8/F9 do nothing. `Bundle.main` resolves
    # to the .app however the binary is launched, so the wrapped executable
    # still behaves as an ordinary CLI and the symlink below is all a user
    # ever needs to touch.
    app = prefix/"hum.app"
    (app/"Contents/MacOS").mkpath
    (app/"Contents/MacOS").install ".build/release/hum"
    (app/"Contents/Info.plist").write info_plist

    # Ad-hoc signature: media-key registration wants a stable identity, and
    # an unsigned bundle is re-evaluated by the system on every launch.
    # Built locally, so each install signs its own copy.
    system "codesign", "--force", "--sign", "-",
           "--identifier", "com.hum.player", app

    bin.install_symlink app/"Contents/MacOS/hum"
  end

  def info_plist
    <<~PLIST
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>CFBundleName</key>               <string>hum</string>
        <key>CFBundleDisplayName</key>        <string>hum</string>
        <key>CFBundleExecutable</key>         <string>hum</string>
        <key>CFBundleIdentifier</key>         <string>com.hum.player</string>
        <key>CFBundlePackageType</key>        <string>APPL</string>
        <key>CFBundleShortVersionString</key> <string>#{version}</string>
        <key>CFBundleVersion</key>            <string>#{version}</string>
        <key>LSMinimumSystemVersion</key>     <string>14.0</string>
        <!-- Agent, not a dock app: hum lives in a terminal and only opens a
             window for the visualiser. -->
        <key>LSUIElement</key>                <true/>
        <key>NSHighResolutionCapable</key>    <true/>
      </dict>
      </plist>
    PLIST
  end

  def caveats
    <<~EOS
      hum stores your Plex token in the login keychain. The first run will ask
      for access; subsequent runs will not, unless hum is reinstalled.

      Media keys and Control Center work through the bundle at:
        #{opt_prefix}/hum.app
    EOS
  end

  test do
    # No server and no terminal in the test sandbox, so the useful assertions
    # are that it launches, reports itself, and that the bundle it needs was
    # actually assembled with a valid signature.
    assert_match "hum #{version}", shell_output("#{bin}/hum --version")
    assert_path_exists prefix/"hum.app/Contents/Info.plist"
    system "codesign", "--verify", "--deep", prefix/"hum.app"
  end
end
