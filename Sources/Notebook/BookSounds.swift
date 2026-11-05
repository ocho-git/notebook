#if os(iOS)
import AVFoundation
import Synchronization

// Procedural page sounds follow the actual page velocity and curl. A held page is quiet;
// landing on a stack produces a soft flap. Cover motion, flight and stowing are silent.
// Audio session configuration belongs to the host application.

@MainActor
final class BookSounds {
    /// The host audio session determines mixing and Silent mode behavior.
    var enabled = true {
        didSet { if !enabled { pause() } }
    }
    private let engine = AVAudioEngine()
    private let voice: BookSoundVoice
    private var node: AVAudioSourceNode?
    private var resting: Task<Void, Never>?
    private static let rate = 44_100.0

    init(feed: BookSoundFeed) {
        voice = BookSoundVoice(feed: feed, rate: Float(Self.rate))
    }

    /// The book is about to move: the synth runs (it rests once the book has been still a moment, `rest()`).
    func wake() {
        resting?.cancel()
        resting = nil
        guard enabled else { return }
        if node == nil {
            let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!
            let node = voice.makeNode(format: format)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            self.node = node
        }
        if !engine.isRunning { try? engine.start() }
    }

    /// The book is still: the last sounds ring out, then the engine rests.
    func rest() {
        resting?.cancel()
        resting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            self.pause()
        }
    }

    func suspend() {
        resting?.cancel()
        resting = nil
        pause()
    }

    private func pause() {
        if engine.isRunning { engine.pause() }
    }
}

/// The synth on the audio thread: reads the feed once a render and plays. Only the audio thread touches `synth`.
nonisolated final class BookSoundVoice: @unchecked Sendable {
    private let feed: BookSoundFeed
    private var synth: BookSynth

    init(feed: BookSoundFeed, rate: Float) {
        self.feed = feed
        synth = BookSynth(rate: rate)
    }

    /// The source node (made here, off the main actor: its block runs on the audio thread).
    func makeNode(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [self] silence, _, frames, buffers in
            render(Int(frames), into: UnsafeMutableAudioBufferListPointer(buffers), silence: silence)
            return noErr
        }
    }

    private func render(_ frames: Int, into buffers: UnsafeMutableAudioBufferListPointer,
                silence: UnsafeMutablePointer<ObjCBool>) {
        guard buffers.count >= 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        let sounding = synth.render(feed, left: left, right: right, frames: frames)
        if !sounding { silence.pointee = true }
    }
}
#endif

#if canImport(Synchronization)
import Foundation
import Synchronization

/// The book's movement, from the renderer's thread (each frame) to the audio thread, lock-free: how fast the leaves, the
/// cover and the book move, and the moments something lands, each stamped with its frame (one read late, after a rest,
/// is let go).
final class BookSoundFeed: Sendable {
    struct Motion {
        /// The leaves in the air: how fast they turn together (rad/s), how fast they bend (rad/s, most mid-turn), and
        /// the one under a finger (rad/s); where they are across the book (−1 left … 1 right).
        var air: Float = 0
        var bend: Float = 0
        var finger: Float = 0
        var pan: Float = 0
        /// The cover's swing (rad/s) and its angle (0 shut … π open).
        var cover: Float = 0
        var coverAngle: Float = 0
        /// The book moving through the air (its flight and a finger pulling it down: about 1 at full pace), sliding
        /// along its edge (about 1 at full pace).
        var book: Float = 0
        var slide: Float = 0
    }

    enum Hit: Int, CaseIterable {
        /// A leaf lands on the left stack or the right one; the cover comes to rest open; it shuts; the book is lifted
        /// from its place; it is set down there.
        case leafLeft, leafRight, coverOpen, coverShut, lift, down
    }

    private struct Value: ~Copyable, Sendable {
        let bits = Atomic<UInt32>(0)
        func store(_ value: Float) { bits.store(value.bitPattern, ordering: .relaxed) }
        func load() -> Float { Float(bitPattern: bits.load(ordering: .relaxed)) }
    }

    private let frame = Atomic<UInt32>(0)
    private let air = Value(), bend = Value(), finger = Value(), pan = Value()
    private let cover = Value(), coverAngle = Value(), book = Value(), slide = Value()
    /// Each hit: its strength's bits (high half) and its frame (low half).
    private let leafLeft = Atomic<UInt64>(0), leafRight = Atomic<UInt64>(0), coverOpen = Atomic<UInt64>(0)
    private let coverShut = Atomic<UInt64>(0), lift = Atomic<UInt64>(0), down = Atomic<UInt64>(0)

    init() {}

    private func slot<R>(_ hit: Hit, _ body: (borrowing Atomic<UInt64>) -> R) -> R {
        switch hit {
        case .leafLeft: body(leafLeft)
        case .leafRight: body(leafRight)
        case .coverOpen: body(coverOpen)
        case .coverShut: body(coverShut)
        case .lift: body(lift)
        case .down: body(down)
        }
    }

    /// The renderer's thread: this frame's motion and what landed in it (0: nothing).
    func write(_ motion: Motion, hits: (Hit) -> Float) {
        let next = frame.load(ordering: .relaxed) &+ 1
        air.store(motion.air); bend.store(motion.bend); finger.store(motion.finger); pan.store(motion.pan)
        cover.store(motion.cover); coverAngle.store(motion.coverAngle); book.store(motion.book); slide.store(motion.slide)
        for hit in Hit.allCases {
            let strength = hits(hit)
            if strength > 0 { slot(hit) { $0.store(UInt64(strength.bitPattern) << 32 | UInt64(next), ordering: .relaxed) } }
        }
        frame.store(next, ordering: .releasing)
    }

    /// The audio thread: the latest frame's number and motion.
    func read() -> (frame: UInt32, motion: Motion) {
        let at = frame.load(ordering: .acquiring)
        return (at, Motion(air: air.load(), bend: bend.load(), finger: finger.load(), pan: pan.load(), cover: cover.load(),
                           coverAngle: coverAngle.load(), book: book.load(), slide: slide.load()))
    }

    /// The audio thread: a hit's last frame and strength.
    func hit(_ hit: Hit) -> (frame: UInt32, strength: Float) {
        let packed = slot(hit) { $0.load(ordering: .relaxed) }
        return (UInt32(truncatingIfNeeded: packed), Float(bitPattern: UInt32(truncatingIfNeeded: packed >> 32)))
    }
}

/// How the book moves, for its sounds: worked out each frame from the renderer's springs (on its thread) and written to
/// the feed. Fed leaf by leaf, then the book, then `finish`.
struct BookSoundTracker {
    private var motion = BookSoundFeed.Motion()
    /// This frame's leaves in the air: the fastest and the rest (summed), how many, and the pan's sums.
    private var fastest: Float = 0, others: Float = 0, fastestBend: Float = 0, otherBend: Float = 0, inAir = 0
    /// Leaves landing this frame, the fastest on each side (left, right).
    private var landing: (Float, Float) = (0, 0)
    private var turning: Float = 0, panned: Float = 0
    private var hits: [Float] = Array(repeating: 0, count: BookSoundFeed.Hit.allCases.count)
    /// Each leaf: off its stack since it last lay still, and how fast it turned last frame (a leaf is stopped by its
    /// stack in the frame it lands).
    private var away: [Bool] = []
    private var lastSpeed: [Float] = []
    private var lastCover: Float = 0
    private var lastFlight: Float = 0
    private var lastLowered: Float?

    init() {}

    /// A leaf this frame: its turn (0 right … π left), how fast, where it is going, and whether a finger holds it.
    mutating func leaf(_ i: Int, angle: Float, velocity: Float, target: Float, held: Bool) {
        if away.count <= i {
            away += Array(repeating: false, count: i + 1 - away.count)
            lastSpeed += Array(repeating: 0, count: i + 1 - lastSpeed.count)
        }
        let speed = abs(velocity)
        if speed > 0.02 {
            let bend = speed * (0.3 + 0.7 * sin(max(0, min(.pi, angle))))
            if speed > fastest { others += fastest; fastest = speed } else { others += speed }
            if bend > fastestBend { otherBend += fastestBend; fastestBend = bend } else { otherBend += bend }
            inAir += 1
            turning += speed
            panned += speed * cos(angle)
        }
        if held { motion.finger = max(motion.finger, speed) }
        let off = abs(angle - target)
        if off > 0.35 {
            away[i] = true
        } else if away[i], off < 0.05 {
            away[i] = false
            let speed = max(speed, lastSpeed[i], 0.001)
            if target > .pi / 2 { landing.0 = max(landing.0, speed) } else { landing.1 = max(landing.1, speed) }
        }
        lastSpeed[i] = speed
    }

    /// The book this frame: its cover (angle, speed, where it is going), its flight from its place (0) to the middle (1),
    /// its step off the screen (speed), and how far a finger pulls it down (points; nil: not held), over `dt`.
    mutating func book(cover: Float, coverVelocity: Float, coverTarget: Float, flight: Float, flightVelocity: Float,
                       flightTarget: Float, stowVelocity: Float, lowered: Float?, dt: Float) {
        motion.cover = abs(coverVelocity)
        motion.coverAngle = cover
        if coverTarget > 0, lastCover < 0.94 * .pi, cover >= 0.94 * .pi {
            hits[BookSoundFeed.Hit.coverOpen.rawValue] = max(abs(coverVelocity), 0.001)
        }
        if coverTarget == 0, lastCover > 0.06, cover <= 0.06 {
            hits[BookSoundFeed.Hit.coverShut.rawValue] = max(abs(coverVelocity), 0.001)
        }
        if flightTarget > 0, lastFlight < 0.004, flight >= 0.004 {
            hits[BookSoundFeed.Hit.lift.rawValue] = max(abs(flightVelocity), 0.001)
        }
        if flightTarget == 0, lastFlight > 0.02, flight <= 0.02 {
            hits[BookSoundFeed.Hit.down.rawValue] = max(abs(flightVelocity), 0.001)
        }
        // Pulled down by a finger: its pace in points a second (about 1500 is a brisk pull).
        var pulled: Float = 0
        if let lowered, let last = lastLowered, dt > 0 { pulled = abs(lowered - last) / dt / 1500 }
        motion.book = abs(flightVelocity) / 3.7 + pulled
        motion.slide = abs(stowVelocity) / 4
        lastCover = cover
        lastFlight = flight
        lastLowered = lowered
    }

    /// Writes the frame to `feed` and starts the next. `snap`: a jump, heard as nothing.
    mutating func finish(into feed: BookSoundFeed, snap: Bool) {
        if snap {
            motion = .init()
            for i in hits.indices { hits[i] = 0 }
            for i in away.indices { away[i] = false }
            landing = (0, 0)
        }
        // Several leaves at once (a riffle) go over as a sheaf: a little more than the fastest alone, not all of them
        // over again; one lands among others still turning on moving paper, softer, part of their patter.
        let sheaf = 1 + 0.5 * Float(max(0, inAir - 1))
        motion.air = (fastest + 0.1 * others) / sheaf
        motion.bend = (fastestBend + 0.1 * otherBend) / sheaf
        let among = 1 + 1.2 * Float(max(0, inAir - 1))
        if landing.0 > 0 { hits[BookSoundFeed.Hit.leafLeft.rawValue] = max(landing.0 / among, 0.001) }
        if landing.1 > 0 { hits[BookSoundFeed.Hit.leafRight.rawValue] = max(landing.1 / among, 0.001) }
        motion.pan = turning > 0 ? panned / turning : 0
        let hits = hits
        feed.write(motion) { hits[$0.rawValue] }
        motion = .init()
        fastest = 0; others = 0; fastestBend = 0; otherBend = 0; inAir = 0
        landing = (0, 0)
        turning = 0
        panned = 0
        for i in self.hits.indices { self.hits[i] = 0 }
    }
}

/// The book's sounds as numbers, on the audio thread: noise shaped by soft filters into air and paper fibre, and small
/// grains of paper at the rate the leaves' motion asks for; each page's landing a few such parts struck together. Nothing
/// rings (no resonance sharper than Q 2), nothing thumps (no part of it below about 400 Hz: Jip, 4 Nov, pages are
/// "feathery light" and only rub, and the book comes and goes subtly). A page lives high and dry, mostly between 2.5
/// and 7 kHz (still "too wet/heavy" when its body sat at 0.5–2 kHz); the whole is rolled off above 9 kHz.
struct BookSynth {
    /// Each layer's level (linear), and all of them against the garden (`level`). Measured offline against the
    /// soundscape's bed and music at its master and the rake at a middling stroke (momentary loudness, through a phone
    /// speaker's roll-off below 350 Hz; the garden typically −52, the rake −48 LUFS): a page tapped over −54.3 (1.0.2 (11):
    /// −32.6, (12): −45.5), a flick −52.8, a riffle −51.4, a slow hand's page −58.5 (pages "still too loud"). A page's landing sits under its rub; under 3% of a
    /// page's sound is below 500 Hz ((12): 30%), and about three quarters is above 2 kHz (a third before 5 Nov).
    struct Mix {
        var level: Float = 0.063
        var air: Float = 0.12, hush: Float = 0.075, paper: Float = 0.115
        var leaf: Float = 0.25
    }

    var mix = Mix()
    let rate: Float
    private var random = SplitMix(seed: 0xB00C_F1E1D)
    private var lastFrame: UInt32 = 0
    /// Audio samples since the feed last moved on (the renderer rests: everything settles to quiet).
    private var stale = 0
    private var lastHits: [UInt32] = Array(repeating: 0, count: BookSoundFeed.Hit.allCases.count)

    /// The motion as heard: each followed smoothly (quick to rise, slower to fall).
    private var air: Float = 0, bend: Float = 0, finger: Float = 0, pan: Float = 0

    private var airLow = (OnePole(), OnePole()), airHigh = OnePole(), flutter = OnePole()
    private var hush = Biquad()
    private var softLeft = (OnePole(), OnePole()), softRight = (OnePole(), OnePole())
    private var grains = [Grain](repeating: Grain(), count: 64)
    private var thuds = [Thud](repeating: Thud(), count: 8)

    init(rate: Float) {
        self.rate = rate
        hush = .bandpass(4500, q: 0.7, rate: rate)
    }

    /// Renders `frames` into the two channels from the feed's latest motion; false: silence (nothing sounding).
    mutating func render(_ feed: BookSoundFeed, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                         frames: Int) -> Bool {
        let (frame, motion) = feed.read()
        if frame != lastFrame { lastFrame = frame; stale = 0 } else { stale += frames }
        let still = stale > Int(rate * 0.1)
        for hit in BookSoundFeed.Hit.allCases {
            let (stamp, strength) = feed.hit(hit)
            // A hit stamped with a frame not yet counted waits for the next render; one 8 frames old is let go.
            let age = frame &- stamp
            guard stamp != lastHits[hit.rawValue], age < 1 << 31 else { continue }
            lastHits[hit.rawValue] = stamp
            if age < 8, hit == .leafLeft || hit == .leafRight { strike(hit, strength) }
        }

        // Each motion as a level 0…1 (its full pace).
        let target = (air: still ? 0 : min(1, motion.air / 16), bend: still ? 0 : min(1, motion.bend / 14),
                      finger: still ? 0 : min(1, motion.finger / 6))
        let quiet = target.air + target.bend + target.finger < 0.001 && air + bend + finger < 0.0005
            && !grains.contains(where: \.on) && !thuds.contains(where: \.on)
        if quiet {
            air = 0; bend = 0; finger = 0
            for i in 0..<frames { left[i] = 0; right[i] = 0 }
            return false
        }
        let rise = 1 - exp(-1 / (0.012 * rate)), fall = 1 - exp(-1 / (0.04 * rate))
        func follow(_ value: inout Float, _ to: Float) { value += (to - value) * (to > value ? rise : fall) }
        let glide = 1 - exp(-1 / (0.03 * rate))
        let level = mix.level

        // The filters that follow the motion are tuned once a render (about every 10 ms).
        let airTone = OnePole.coefficient(3000 + 3000 * air, rate: rate)
        let highTone = OnePole.coefficient(1800, rate: rate)
        let flutterTone = OnePole.coefficient(9, rate: rate)
        let softTone = OnePole.coefficient(9000, rate: rate)

        for i in 0..<frames {
            follow(&air, target.air); follow(&bend, target.bend); follow(&finger, target.finger)
            pan += (motion.pan - pan) * glide
            var leafSound: Float = 0

            // A leaf in the air: its breath (light and dry, rising in tone with its pace, never quite steady) and the
            // hush of its fibres against the next page's as it bends and moves, with grains of paper at the rate it
            // bends (a finger on it adds its own).
            if air > 0.0005 {
                let n = noise()
                let low = airLow.1.low(airLow.0.low(n, airTone), airTone)
                let body = low - airHigh.low(low, highTone)
                let wobble = 1 + max(-0.15, min(0.15, 6 * flutter.low(noise(), flutterTone)))
                leafSound += body * wobble * air * mix.air
            }
            let rub = max(bend, 0.7 * finger, 0.5 * air)
            if rub > 0.0005 {
                leafSound += hush.process(noise()) * pow(rub, 0.6) * mix.hush
            }
            let paperRate = 240 * pow(bend, 1.3) + 160 * finger + 80 * air
            if paperRate > 0.1, random.unit() < paperRate / rate {
                grain(level: 0.5 + 0.5 * max(bend, finger), pan: pan)
            }

            var l = leafSound * (1 - max(0, pan) * 0.35)
            var r = leafSound * (1 + min(0, pan) * 0.35)
            for g in grains.indices where grains[g].on {
                let (gl, gr) = grains[g].next(noise())
                l += gl; r += gr
            }
            for t in thuds.indices where thuds[t].on {
                let (tl, tr, spawn) = thuds[t].next(noise(), rate: rate)
                l += tl; r += tr
                if spawn > 0, random.unit() < spawn {
                    grain(level: thuds[t].grainLevel, pan: thuds[t].pan)
                }
            }
            l = softLeft.1.low(softLeft.0.low(l, softTone), softTone)
            r = softRight.1.low(softRight.0.low(r, softTone), softTone)
            left[i] = max(-0.5, min(0.5, l * level))
            right[i] = max(-0.5, min(0.5, r * level))
        }
        return true
    }

    private mutating func noise() -> Float { random.unit() * 2 - 1 }

    // MARK: - Grains

    /// A grain of paper: 0.3–1.2 ms of noise through a soft band between about 2.5 and 7 kHz; their sizes run from many
    /// small to a few larger (a power law, as crackle does).
    struct Grain {
        var on = false
        var age = 0, length = 1
        var gain: Float = 0, left: Float = 0, right: Float = 0
        var band = Biquad()

        mutating func next(_ noise: Float) -> (Float, Float) {
            let u = Float(age) / Float(length)
            let e = u < 0.25 ? pow(sin(.pi / 2 * u / 0.25), 2) : pow(cos(.pi / 2 * (u - 0.25) / 0.75), 2)
            let x = band.process(noise) * e * gain
            age += 1
            if age >= length { on = false }
            return (x * left, x * right)
        }
    }

    private mutating func grain(level: Float, pan: Float) {
        guard let slot = grains.firstIndex(where: { !$0.on }) else { return }
        let size = min(3, pow(max(random.unit(), 0.01), -1 / 2.4))
        var g = Grain()
        g.on = true
        let centre = 2500 * pow(7000 / 2500, random.unit())
        g.length = Int(rate * (0.0003 + 0.0009 * random.unit()))
        g.band = .bandpass(centre, q: 0.7 + 0.4 * random.unit(), rate: rate)
        g.gain = size * level * mix.paper
        let place = max(-1, min(1, pan + (random.unit() - 0.5) * 0.3))
        g.left = 1 - max(0, place) * 0.35
        g.right = 1 + min(0, place) * 0.35
        grains[slot] = g
    }

    // MARK: - Landings

    /// One part of a landing: noise through a soft filter (its cut-off gliding, for the air pressed out of a shutting
    /// book), with a smooth attack and an exponential fall.
    struct Part {
        var on = false
        var filter = Biquad()
        var kind = Biquad.Kind.lowpass
        var q: Float = 0.7
        var attack: Float = 1, decay: Float = 1
        var level: Float = 0
        var from: Float = 0, to: Float = 0, glide: Float = 0

        static func make(_ kind: Biquad.Kind, _ f: Float, q: Float = 0.7, attack: Float, decay: Float, level: Float,
                         glideFrom: Float? = nil, glide: Float = 0, rate: Float) -> Part {
            var part = Part()
            part.on = true
            part.kind = kind
            part.q = q
            part.filter = Biquad().retuned(kind, glideFrom ?? f, q: q, rate: rate)
            part.attack = attack * rate
            part.decay = decay * rate
            part.level = level
            part.from = glideFrom ?? f
            part.to = f
            part.glide = glide * rate
            return part
        }

        mutating func next(_ noise: Float, age: Int, rate: Float) -> Float {
            guard on else { return 0 }
            let t = Float(age)
            if glide > 0, age % 16 == 0 {
                filter = filter.retuned(kind, to + (from - to) * exp(-t / glide), q: q, rate: rate)
            }
            let e = (1 - exp(-t / attack)) * exp(-t / decay)
            return filter.process(noise) * e * level
        }
    }

    /// A landing: up to three parts struck together, and a little scatter of grains (pages settling, sand).
    struct Thud {
        var on = false
        var age = 0, length = 0
        var gain: Float = 0, pan: Float = 0
        var parts = (Part(), Part(), Part())
        var grainLevel: Float = 0
        /// Grains still to come, over the samples left for them.
        var grainsLeft: Float = 0, grainSpan: Float = 1

        /// The next sample (left, right) and the chance a grain starts with it.
        mutating func next(_ noise: Float, rate: Float) -> (Float, Float, Float) {
            let x = (parts.0.next(noise, age: age, rate: rate) + parts.1.next(noise, age: age, rate: rate)
                     + parts.2.next(noise, age: age, rate: rate)) * gain
            var spawn: Float = 0
            if grainsLeft > 0, Float(age) < grainSpan {
                spawn = grainsLeft / max(1, grainSpan - Float(age))
                if spawn >= 1 { spawn = 1 }
            }
            age += 1
            if age >= length { on = false }
            return (x * (1 - max(0, pan) * 0.35), x * (1 + min(0, pan) * 0.35), spawn)
        }
    }

    /// A page landing on its stack; `strength`: how fast it came (rad/s).
    private mutating func strike(_ hit: BookSoundFeed.Hit, _ strength: Float) {
        guard let slot = thuds.firstIndex(where: { !$0.on }) else { return }
        var t = Thud()
        t.on = true
        let r = rate
        // No thud, only paper sliding onto paper, a short hush and a few grains of it.
        let s = min(1, strength / 6)
        t.gain = (0.25 + 0.75 * s) * mix.leaf
        t.pan = hit == .leafLeft ? -0.25 : 0.25
        t.parts = (.make(.bandpass, 4200, q: 0.6, attack: 0.004, decay: 0.016, level: 1, rate: r),
                   .make(.bandpass, 2600, q: 0.7, attack: 0.003, decay: 0.01, level: 0.3, rate: r),
                   Part())
        t.grainLevel = 0.25 + 0.25 * s; t.grainsLeft = 1 + 3 * s; t.grainSpan = 0.04 * r
        t.length = Int(0.12 * r)
        thuds[slot] = t
    }
}

/// A one-pole low-pass (its high-pass: the input less it).
struct OnePole {
    var y: Float = 0

    static func coefficient(_ f: Float, rate: Float) -> Float { 1 - exp(-2 * .pi * f / rate) }

    mutating func low(_ x: Float, _ a: Float) -> Float {
        y += a * (x - y)
        return y
    }
}

/// A second-order filter (RBJ's cookbook): low-, high- and band-pass.
struct Biquad {
    enum Kind { case lowpass, highpass, bandpass }
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    static func lowpass(_ f: Float, q: Float, rate: Float) -> Biquad { Biquad().retuned(.lowpass, f, q: q, rate: rate) }
    static func highpass(_ f: Float, q: Float, rate: Float) -> Biquad { Biquad().retuned(.highpass, f, q: q, rate: rate) }
    static func bandpass(_ f: Float, q: Float, rate: Float) -> Biquad { Biquad().retuned(.bandpass, f, q: q, rate: rate) }

    /// The same filter state with new coefficients (a sweep keeps its memory).
    func retuned(_ kind: Kind, _ f: Float, q: Float, rate: Float) -> Biquad {
        let w = 2 * Float.pi * min(f, rate * 0.45) / rate, c = cos(w), alpha = sin(w) / (2 * q)
        var b: (Float, Float, Float)
        switch kind {
        case .lowpass: b = ((1 - c) / 2, 1 - c, (1 - c) / 2)
        case .highpass: b = ((1 + c) / 2, -(1 + c), (1 + c) / 2)
        case .bandpass: b = (alpha, 0, -alpha)
        }
        let a0 = 1 + alpha
        var next = self
        next.b0 = b.0 / a0; next.b1 = b.1 / a0; next.b2 = b.2 / a0
        next.a1 = -2 * c / a0; next.a2 = (1 - alpha) / a0
        return next
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}
#endif
