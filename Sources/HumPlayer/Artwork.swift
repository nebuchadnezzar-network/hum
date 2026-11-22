import AppKit
import Foundation
import MediaPlayer

/// Wraps image data as `MPMediaItemArtwork` for Control Center and the Now
/// Playing panel. Kept apart from `Player` so AppKit stays out of the transport.
func makeArtwork(from data: Data) -> MPMediaItemArtwork? {
    guard let image = NSImage(data: data) else { return nil }
    return MPMediaItemArtwork(boundsSize: image.size) { requested in
        // Control Center asks for several sizes; redraw rather than hand back the
        // original, or the system scales it badly.
        let scaled = NSImage(size: requested)
        scaled.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: requested),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        scaled.unlockFocus()
        return scaled
    }
}
