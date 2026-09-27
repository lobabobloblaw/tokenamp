import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UsageModel

/// Offscreen rendering (SPEC 3.1). No windows, no Screen Recording permission, no window server:
/// just the shared renderers drawing into bitmap contexts.
public enum SnapshotRunner {

    public struct Result {
        public var files: [URL]
        public var warnings: [String]
        public var skinName: String
    }

    /// Render `main.png`, `eq.png`, `playlist.png`, `shade.png`, one `field-<mode>.png` per
    /// Token Flow configuration, and `all.png` into `directory`.
    @discardableResult
    public static func run(directory: String, skin: Skin, snapshot: UsageSnapshot, scale: Int,
                           stateName: String?, now: Date) throws -> Result {
        let dir = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var state = makeState(snapshot: snapshot, scale: scale, now: now,
                              playlistRowHeight: skin.playlistRowHeight)
        if stateName?.lowercased() == "pressed" {
            // Exercise the alternate sprites: play held down, EQ toggle held (on an open EQ, so
            // the pressed-and-lit sprite), volume thumb grabbed, A latched where the normal state
            // latches V.
            state.pressed = [.play, .eqToggle, .volume, .eqOn, .plScroll, .clutter("D")]
            state.eqOpen = true
            state.latchedClutter = ["A"]
            state.playlistSelection = min(1, max(0, snapshot.sessionsToday.count - 1))
        }

        var files: [URL] = []

        let mainImage = try render(width: Layout.Main.size.w, height: Layout.Main.size.h, scale: scale) { c in
            MainRenderer.draw(c, skin: skin, snapshot: snapshot, state: state)
        }
        try write(mainImage, to: dir.appendingPathComponent("main.png"), &files)

        let eqImage = try render(width: Layout.EQ.size.w, height: Layout.EQ.size.h, scale: scale) { c in
            EQRenderer.draw(c, skin: skin, snapshot: snapshot, state: state)
        }
        try write(eqImage, to: dir.appendingPathComponent("eq.png"), &files)

        let plImage = try render(width: state.playlistWidth, height: state.playlistHeight, scale: scale) { c in
            PlaylistRenderer.draw(c, skin: skin, snapshot: snapshot, state: state)
        }
        try write(plImage, to: dir.appendingPathComponent("playlist.png"), &files)

        var shadeState = state
        shadeState.shadeMode = true
        let shadeImage = try render(width: Layout.Shade.size.w, height: Layout.Shade.size.h, scale: scale) { c in
            MainRenderer.drawShade(c, skin: skin, snapshot: snapshot, state: shadeState)
        }
        try write(shadeImage, to: dir.appendingPathComponent("shade.png"), &files)

        // The Token Flow window, one file per configuration: the whole point of the module is
        // that the geometry changes with the state, and one golden cannot show that (SPEC 2.9).
        let fieldW = Layout.Field.defaultSize.w
        let fieldH = Layout.Field.defaultSize.h
        for mode in FieldMode.allCases {
            var fieldState = state
            fieldState.fieldMode = mode
            fieldState.fieldWidth = fieldW
            fieldState.fieldHeight = fieldH
            let settled = FieldRenderer.settled(snapshot: snapshot, skin: skin, mode: mode,
                                                span: fieldState.fieldSpan, width: fieldW,
                                                height: fieldH, now: now)
            let image = try render(width: fieldW, height: fieldH, scale: scale) { c in
                FieldRenderer.draw(c, skin: skin, snapshot: snapshot, state: fieldState,
                                   field: settled.image, labels: settled.labels)
            }
            try write(image, to: dir.appendingPathComponent("field-\(mode.rawValue).png"), &files)
        }

        // all.png: the three classic windows stacked, main over EQ over playlist (a contact sheet,
        // not the default layout, which is main / Sessions / Token Flow with the EQ closed). The
        // main window is main.png's, so its toggles show the default state: EQ unlit, V latched.
        let totalH = Layout.Main.size.h + Layout.EQ.size.h + state.playlistHeight
        let allImage = try render(width: Layout.Main.size.w, height: totalH, scale: scale) { c in
            MainRenderer.draw(c, skin: skin, snapshot: snapshot, state: state)
            c.save()
            c.ctx.translateBy(x: 0, y: CGFloat(Layout.Main.size.h))
            EQRenderer.draw(c, skin: skin, snapshot: snapshot, state: state)
            c.ctx.translateBy(x: 0, y: CGFloat(Layout.EQ.size.h))
            PlaylistRenderer.draw(c, skin: skin, snapshot: snapshot, state: state)
            c.restore()
        }
        try write(allImage, to: dir.appendingPathComponent("all.png"), &files)

        return Result(files: files, warnings: skin.warnings, skinName: skin.name)
    }

    // MARK: - Frame sequences (--frames)

    /// The demo provider publishes twice a second (`DemoUsageProvider.start`), and the sequence
    /// takes new data on the same beat, so it animates on the data the running app would have.
    static let publishesPerSecond = 2

    /// Render `count` frames of the default layout as it animates, `frame-0000.png` onwards, into
    /// `directory`: frame `i` is the app `i / fps` seconds after `start`, with the clock, the data,
    /// the marquee, the visualizer and the Token Flow persistence advanced the way the app's own
    /// tick advances them (see `renderFrames`).
    @discardableResult
    public static func runFrames(directory: String, skin: Skin, count: Int, fps: Int, scale: Int,
                                 fieldMode: FieldMode, start: Date,
                                 snapshotAt: (Date) -> UsageSnapshot) throws -> Result {
        let dir = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [URL] = []
        try renderFrames(skin: skin, count: count, fps: fps, scale: scale, fieldMode: fieldMode,
                         start: start, snapshotAt: snapshotAt) { index, image in
            let name = String(format: "frame-%04d.png", index)
            try write(image, to: dir.appendingPathComponent(name), &files)
        }
        return Result(files: files, warnings: skin.warnings, skinName: skin.name)
    }

    /// How long the display runs before frame 0, by default: six time constants of the field's
    /// slower (ghost) channel, the run `FieldRenderer.settle` also allows. A settled field is one
    /// instant's trace; a running one also carries the trails of where the trace has just been,
    /// and without this lead-in the first seconds of a sequence would show the one growing into
    /// the other - and a looping animation would snap back to the settled trace on every loop.
    static func warmup(snapshot: UsageSnapshot, mode: FieldMode, now: Date) -> TimeInterval {
        FieldModulators(snapshot: snapshot, now: now).tail(for: mode) * 2.2 * 6
    }

    /// The frames `runFrames` writes, handed to `body` in order instead of to disk.
    ///
    /// The display starts `warmup` seconds before `start` (by default `warmup(snapshot:mode:now:)`)
    /// from a settled state, as the app does at launch, and runs in steps of `1 / fps`: the data
    /// on the provider's beat, the visualizer's bars and caps, the field's decay and beam. The
    /// marquee is the exception: it starts at the head of its text on frame 0, so the first frame -
    /// the one a paused animation shows - reads from the beginning. With no warm-up, frame 0 is
    /// the still `run` renders for `start`.
    ///
    /// Deterministic: time comes only from `start` and the frame index, data only from
    /// `snapshotAt`, and the visualizer's shimmer from its own seeded generator. The per-session
    /// flow WEB would recover by diffing snapshots is left out, as it is in the stills, so a
    /// sequence and a still of the same data agree.
    public static func renderFrames(skin: Skin, count: Int, fps: Int, scale: Int,
                                    fieldMode: FieldMode, start: Date, warmup lead: TimeInterval? = nil,
                                    snapshotAt: (Date) -> UsageSnapshot,
                                    _ body: (Int, CGImage) throws -> Void) throws {
        let fps = max(1, fps)
        let dt = 1 / Double(fps)
        let rows = Layout.Main.visualizer.h
        /// Frame `i`'s instant; negative frames are the warm-up.
        func clock(_ i: Int) -> Date { start.addingTimeInterval(Double(i) / Double(fps)) }
        /// The provider beat frame `i` falls in, counted from `start`.
        func beat(_ i: Int) -> Int { Int((Double(i * publishesPerSecond) / Double(fps)).rounded(.down)) }

        let lead = lead ?? warmup(snapshot: snapshotAt(start), mode: fieldMode, now: start)
        let first = -Int((max(0, lead) * Double(fps)).rounded(.up))

        var published = beat(first)
        var snapshot = snapshotAt(clock(first))
        var state = makeState(snapshot: snapshot, scale: scale, now: clock(first),
                              playlistRowHeight: skin.playlistRowHeight)
        state.fieldMode = fieldMode
        var marqueeOffset = 0.0

        let visualizer = VisualizerModel()
        visualizer.settle(snapshot: snapshot, rows: rows)
        let well = FieldRenderer.canvasRect(width: state.fieldWidth, height: state.fieldHeight)
        let field = PhosphorField(width: well.w, height: well.h)
        let metrics = FieldRenderer.labelMetrics(for: skin)
        var labels = FieldRenderer.settle(into: field, snapshot: snapshot, mode: fieldMode,
                                          span: state.fieldSpan, now: clock(first), metrics: metrics)
        var elapsed = 0.0

        for index in first..<max(0, count) {
            let now = clock(index)
            if index > first {
                // One step of TokenampController.tick and FieldWindowController.animate.
                if beat(index) != published {
                    published = beat(index)
                    snapshot = snapshotAt(start.addingTimeInterval(Double(published) / Double(publishesPerSecond)))
                }
                visualizer.advance(snapshot: snapshot, now: now, dt: dt, rows: rows)
                let mods = FieldModulators(snapshot: snapshot, now: now)
                elapsed += dt
                field.decay(dt: dt, persistence: mods.tail(for: fieldMode))
                labels = FieldGeometry.draw(fieldMode, into: field, snapshot: snapshot, mods: mods,
                                            span: state.fieldSpan, flows: [:], t: elapsed, now: now,
                                            metrics: metrics)
                FieldGeometry.drawGraticule(field, fieldMode, mods)
            }
            guard index >= 0 else { continue }

            if index > 0 { marqueeOffset = Marquee.scrolled(marqueeOffset, by: dt, text: state.marqueeText) }
            // The app recomposes on every publish and every tick of the digits; the text is a
            // function of the data and the clock, so composing it every frame comes to the same.
            let text = Marquee.compose(snapshot: snapshot, heroIndex: state.heroIndex,
                                       isPaused: false, isStopped: false, now: now)
            if text != state.marqueeText {
                state.marqueeText = text
                if marqueeOffset > Double(Marquee.scrollWidth(text)) { marqueeOffset = 0 }
            }

            state.now = now
            state.visBars = visualizer.bars
            state.visPeaks = visualizer.peaks
            state.visScope = VisualizerModel.scope(snapshot)
            state.marqueeOffset = Int(marqueeOffset)
            let pressure = FieldModulators(snapshot: snapshot, now: now).pressure
            let image = try defaultLayout(skin: skin, snapshot: snapshot, state: state, scale: scale,
                                          field: field.makeImage(skin: skin, pressure: pressure),
                                          labels: labels)
            try body(index, image)
        }
    }

    /// The layout the app opens with: main, Sessions and Token Flow, docked flush in one column
    /// (the EQ starts closed), each window centred on the widest.
    static func defaultLayout(skin: Skin, snapshot: UsageSnapshot, state: ViewState, scale: Int,
                              field: CGImage?, labels: [FieldLabel]) throws -> CGImage {
        let windows: [(size: SkinPair, draw: (SkinCanvas) -> Void)] = [
            (Layout.Main.size, { MainRenderer.draw($0, skin: skin, snapshot: snapshot, state: state) }),
            (SkinPair(state.playlistWidth, state.playlistHeight),
             { PlaylistRenderer.draw($0, skin: skin, snapshot: snapshot, state: state) }),
            (SkinPair(state.fieldWidth, state.fieldHeight),
             { FieldRenderer.draw($0, skin: skin, snapshot: snapshot, state: state, field: field, labels: labels) }),
        ]
        let width = windows.map { $0.size.w }.max() ?? 0
        let height = windows.reduce(0) { $0 + $1.size.h }
        return try render(width: width, height: height, scale: scale) { c in
            var y = 0
            for window in windows {
                c.save()
                c.ctx.translateBy(x: CGFloat((width - window.size.w) / 2), y: CGFloat(y))
                c.clip(to: SpriteRect(0, 0, window.size.w, window.size.h))
                window.draw(c)
                c.restore()
                y += window.size.h
            }
        }
    }

    /// The deterministic view state a snapshot renders: settled visualizer, marquee at the start,
    /// and the Sessions window at the height auto-fit gives this data at the skin's row pitch
    /// (SPEC 2.4, amendment A7) - uncapped, as there is no screen offscreen.
    public static func makeState(snapshot: UsageSnapshot, scale: Int, now: Date,
                                 playlistRowHeight: Int = Layout.Playlist.rowHeight) -> ViewState {
        var state = ViewState()
        state.now = now
        state.scale = Double(scale)
        state.heroIndex = 0
        state.playState = .playing
        state.timeMode = .remaining
        state.workLED = true
        state.shuffleOn = false
        state.repeatOn = true
        // The window indicators of the default layout, as TokenampController.viewState shows them
        // on a first run (Preferences' registered defaults): EQ closed, so its toggle is unlit;
        // Sessions open; Token Flow open, so V is latched; not always-on-top, so A is not.
        state.eqOpen = false
        state.plOpen = true
        state.latchedClutter = ViewState.latchedClutter(alwaysOnTop: false, fieldOpen: true)
        state.mainIsKey = true
        state.eqIsKey = true
        state.playlistIsKey = true
        state.visualizerMode = .spectrum
        let settled = VisualizerModel.settled(snapshot, rows: Layout.Main.visualizer.h)
        state.visBars = settled.bars
        state.visPeaks = settled.peaks
        state.visScope = VisualizerModel.scope(snapshot)
        state.marqueeText = Marquee.compose(snapshot: snapshot, heroIndex: 0, isPaused: false,
                                            isStopped: false, now: now)
        state.marqueeOffset = 0
        state.playlistWidth = Layout.Playlist.defaultSize.w
        state.playlistHeight = PlaylistFit.height(count: snapshot.sessionsToday.count,
                                                  rowHeight: playlistRowHeight)
        state.playlistScroll = 0
        state.playlistShowsCost = true
        state.eqRange = .hours
        state.eqMeasure = .cost
        state.eqRelative = true
        state.fieldMode = .scope
        state.fieldAuto = false
        state.fieldSpan = .minutes
        state.fieldWidth = Layout.Field.defaultSize.w
        state.fieldHeight = Layout.Field.defaultSize.h
        return state
    }

    public enum SnapshotError: Swift.Error, CustomStringConvertible {
        case contextFailed
        case encodeFailed(String)
        public var description: String {
            switch self {
            case .contextFailed: return "could not create a bitmap context"
            case .encodeFailed(let p): return "could not write \(p)"
            }
        }
    }

    static func render(width: Int, height: Int, scale: Int, _ body: (SkinCanvas) -> Void) throws -> CGImage {
        guard let canvas = SkinCanvas.offscreen(width: width, height: height, scale: scale) else {
            throw SnapshotError.contextFailed
        }
        body(canvas)
        guard let image = canvas.makeImage() else { throw SnapshotError.contextFailed }
        return image
    }

    static func write(_ image: CGImage, to url: URL, _ files: inout [URL]) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SnapshotError.encodeFailed(url.path)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw SnapshotError.encodeFailed(url.path) }
        files.append(url)
    }
}
