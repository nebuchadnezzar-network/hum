import AppKit
import HumPlayer
import Metal
import MetalKit
import simd

/// A borderless-ish Metal window showing the spectrum on the GPU.
///
/// This is deliberately optional. The TUI draws its own block-glyph spectrum and
/// works over SSH; this window is the "fat client" experience when you are sitting
/// at the machine. Both read the same `SpectrumAnalyzer`, so they never disagree.
public final class VisualizerWindow: NSObject {
    /// 72 bars reads as a spectrum at typical window widths without turning into
    /// a solid block on a laptop display.
    public static let barCount = 72

    private let analyzer: SpectrumAnalyzer
    private var window: NSWindow?
    private var view: MTKView?
    private var renderer: Renderer?

    public init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
        super.init()
    }

    public var isVisible: Bool { window?.isVisible ?? false }

    /// Errors are returned rather than thrown so the TUI can show a status line
    /// instead of dying when, say, there is no Metal device.
    @discardableResult
    public func show() -> String? {
        assert(Thread.isMainThread, "VisualizerWindow must be driven from the main thread")

        if let window {
            window.makeKeyAndOrderFront(nil)
            view?.isPaused = false
            return nil
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            return "No Metal device available."
        }

        let metalView = MTKView(frame: NSRect(x: 0, y: 0, width: 880, height: 420), device: device)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.clearColor = MTLClearColor(red: 0.055, green: 0.067, blue: 0.086, alpha: 1)  // #0E1116
        metalView.preferredFramesPerSecond = 60
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.autoResizeDrawable = true

        let renderer: Renderer
        do {
            renderer = try Renderer(device: device, analyzer: analyzer, barCount: Self.barCount)
        } catch {
            return "Visualizer unavailable: \(error.localizedDescription)"
        }
        metalView.delegate = renderer

        let window = NSWindow(
            contentRect: metalView.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "hum ))) spectrum"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.055, green: 0.067, blue: 0.086, alpha: 1)
        window.contentView = metalView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
        self.view = metalView
        self.renderer = renderer
        return nil
    }

    public func hide() {
        view?.isPaused = true
        window?.orderOut(nil)
    }

    @discardableResult
    public func toggle() -> String? {
        if isVisible {
            hide()
            return nil
        }
        return show()
    }
}

extension VisualizerWindow: NSWindowDelegate {
    /// Closing the window should stop rendering, not quit hum.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}

// MARK: - Renderer

private final class Renderer: NSObject, MTKViewDelegate {
    enum Failure: Error, LocalizedError {
        case noCommandQueue
        case shaderCompilation(String)
        case missingFunction(String)

        var errorDescription: String? {
            switch self {
            case .noCommandQueue: return "could not create a Metal command queue"
            case .shaderCompilation(let detail): return "shader failed to compile (\(detail))"
            case .missingFunction(let name): return "shader function \(name) missing"
            }
        }
    }

    private let analyzer: SpectrumAnalyzer
    private let barCount: Int
    private let queue: MTLCommandQueue
    private let barPipeline: MTLRenderPipelineState
    private let backdropPipeline: MTLRenderPipelineState
    private let magnitudeBuffer: MTLBuffer
    private var frame: Float = 0
    private var resolution = SIMD2<Float>(1, 1)

    init(device: MTLDevice, analyzer: SpectrumAnalyzer, barCount: Int) throws {
        self.analyzer = analyzer
        self.barCount = barCount

        guard let queue = device.makeCommandQueue() else { throw Failure.noCommandQueue }
        self.queue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            throw Failure.shaderCompilation(error.localizedDescription)
        }

        func function(_ name: String) throws -> MTLFunction {
            guard let function = library.makeFunction(name: name) else {
                throw Failure.missingFunction(name)
            }
            return function
        }

        // Premultiplied-alpha blending: the fragment shaders already multiply
        // colour by alpha so overlapping glow adds instead of darkening.
        func pipeline(vertex: String, fragment: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = try function(vertex)
            descriptor.fragmentFunction = try function(fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        barPipeline = try pipeline(vertex: "barVertex", fragment: "barFragment")
        backdropPipeline = try pipeline(vertex: "backdropVertex", fragment: "backdropFragment")

        guard let buffer = device.makeBuffer(
            length: barCount * MemoryLayout<Float>.stride,
            options: .storageModeShared
        ) else {
            throw Failure.noCommandQueue
        }
        magnitudeBuffer = buffer

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        resolution = SIMD2<Float>(Float(size.width), Float(size.height))
    }

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let magnitudes = analyzer.spectrum(bars: barCount)
        let pointer = magnitudeBuffer.contents().bindMemory(to: Float.self, capacity: barCount)
        for index in 0..<barCount {
            pointer[index] = index < magnitudes.count ? Float(magnitudes[index]) : 0
        }

        frame += 1
        var uniforms = Uniforms(
            barCount: Float(barCount),
            time: frame / 60,
            level: Float(analyzer.level)
        )
        var resolution = self.resolution

        encoder.setRenderPipelineState(backdropPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&resolution, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        encoder.setRenderPipelineState(barPipeline)
        encoder.setVertexBuffer(magnitudeBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        // Doubled: upright bars plus their reflection.
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: barCount * 2
        )

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

private struct Uniforms {
    var barCount: Float
    var time: Float
    var level: Float
    var padding: Float = 0
}
