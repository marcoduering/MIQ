import Foundation

/// AppKit-free description of one scroll-wheel event — the minimal fields
/// `ScrollStepResolver` needs. The view layer maps `NSEvent` → this at the call
/// site, so the state machine has no AppKit dependency and can be unit-tested
/// without synthesising `NSEvent`s.
public struct ScrollStepInput: Sendable {
    public let optionHeld: Bool
    /// The gesture's `.began` phase (latch point for the modifier).
    public let phaseBegan: Bool
    /// Classic mouse wheel: no began/momentum phases, each tick independent and
    /// inertia-free, so the live modifier is authoritative.
    public let isLegacyWheel: Bool
    public let deltaX: Double
    public let deltaY: Double
    public let hasPreciseDeltas: Bool

    public init(
        optionHeld: Bool,
        phaseBegan: Bool,
        isLegacyWheel: Bool,
        deltaX: Double,
        deltaY: Double,
        hasPreciseDeltas: Bool
    ) {
        self.optionHeld = optionHeld
        self.phaseBegan = phaseBegan
        self.isLegacyWheel = isLegacyWheel
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.hasPreciseDeltas = hasPreciseDeltas
    }
}

/// Shared scroll-wheel state machine for slice vs 4D (volume) stepping, used by
/// both the slice canvases and the metadata panel so they behave identically.
///
/// Trackpad scrolling has a finger phase then an inertia/momentum phase. The
/// Option modifier is latched at the gesture's `.began` and held through the
/// momentum, so inertia keeps the same axis; releasing Option during a volume
/// gesture cancels the remainder rather than leaking it into slice scrolling.
/// Classic mouse wheels (no phases, no inertia) use the live modifier.
///
/// This type owns two distinct concerns deliberately kept together because
/// they share the gesture state: (1) classifying each event onto the slice or
/// volume axis, and (2) applying `volumeStepIsInverted` — a *product* decision
/// (4D scrolls opposite to slice scrolling), not an accident. A future reader
/// removing the negation would be reverting an intentional UX choice.
public struct ScrollStepResolver: Sendable {
    public enum Axis: Sendable { case slice, volume }

    /// Deliberate UX rule: a volume step is the negation of the slice step for
    /// the same physical scroll direction. Centralised + named so it reads as
    /// intentional and there's exactly one place to change it.
    public static let volumeStepIsInverted = true

    /// Precise-scroll delta accumulated until it crosses one step's worth.
    private var accumulator: Double = 0
    /// Modifier latched at `.began`, held for the whole gesture + its momentum.
    private var gestureIsVolume = false
    /// Option released mid volume-gesture: swallow the remainder + its inertia.
    private var volumeCancelled = false

    public init() { /* all stored properties have defaults */ }

    /// `onBegan` fires once per gesture start (used to cancel pending renders).
    /// Returns `nil` when the event should produce no step (below threshold,
    /// zero delta, or a cancelled volume gesture being swallowed).
    public mutating func resolve(
        _ input: ScrollStepInput,
        onBegan: () -> Void
    ) -> (axis: Axis, step: Int)? {
        if input.phaseBegan {
            accumulator = 0
            gestureIsVolume = input.optionHeld
            volumeCancelled = false
            onBegan()
        }

        let axis: Axis
        if input.isLegacyWheel {
            axis = input.optionHeld ? .volume : .slice
        } else {
            if gestureIsVolume && !input.optionHeld { volumeCancelled = true }
            if volumeCancelled { return nil }
            axis = gestureIsVolume ? .volume : .slice
        }

        let dominant = abs(input.deltaY) >= abs(input.deltaX) ? input.deltaY : input.deltaX
        guard dominant != 0 else { return nil }

        let direction: Int
        if input.hasPreciseDeltas {
            let threshold = 14.0
            accumulator += dominant
            guard abs(accumulator) >= threshold else { return nil }
            direction = accumulator > 0 ? -1 : 1
            accumulator += accumulator > 0 ? -threshold : threshold
        } else {
            direction = dominant > 0 ? -1 : 1
        }

        let invert = axis == .volume && Self.volumeStepIsInverted
        return (axis, invert ? -direction : direction)
    }
}
