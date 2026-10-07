import SwiftUI

/// The intensity window as a percentile range: exact number fields (with
/// steppers) for single-percent changes, plus a two-handle slider that shows
/// the range at a glance. The lower bound stays in 0…49 and the upper in
/// 51…100, the ranges the windowing code has always accepted.
struct PercentileRangeControl<Label: View>: View {
    @Binding var lower: Double
    @Binding var upper: Double
    @ViewBuilder var label: () -> Label

    static var lowerRange: ClosedRange<Double> { 0...49 }
    static var upperRange: ClosedRange<Double> { 51...100 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                label()
                Spacer()
                PercentField(value: $lower, range: Self.lowerRange, accessibilityName: "Lower percentile")
                Text("–").foregroundStyle(.secondary)
                PercentField(value: $upper, range: Self.upperRange, accessibilityName: "Upper percentile")
                Text("%").foregroundStyle(.secondary)
            }
            PercentileRangeSlider(lower: $lower, upper: $upper)
        }
    }
}

/// A clamped integer percent field with a stepper beside it.
private struct PercentField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let accessibilityName: String

    private var clamped: Binding<Double> {
        Binding(
            get: { value },
            set: { value = min(max($0.rounded(), range.lowerBound), range.upperBound) }
        )
    }

    var body: some View {
        HStack(spacing: 2) {
            TextField(accessibilityName, value: clamped, format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 36)
            Stepper(accessibilityName, value: clamped, in: range, step: 1)
                .labelsHidden()
        }
    }
}

/// Custom because SwiftUI has no two-thumb slider on macOS. Each thumb is its
/// own accessibility element, adjustable with VoiceOver and the arrow keys.
struct PercentileRangeSlider: View {
    @Binding var lower: Double
    @Binding var upper: Double

    private let thumbSize: CGFloat = 18
    private let trackHeight: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - thumbSize, 1)
            let x = { (value: Double) -> CGFloat in CGFloat(value / 100) * usable }
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: trackHeight)
                    .padding(.horizontal, thumbSize / 2)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(x(upper) - x(lower), 0), height: trackHeight)
                    .offset(x: x(lower) + thumbSize / 2)
                thumb(value: $lower, range: PercentileRangeControl<EmptyView>.lowerRange, name: "Lower percentile", usable: usable)
                    .offset(x: x(lower))
                thumb(value: $upper, range: PercentileRangeControl<EmptyView>.upperRange, name: "Upper percentile", usable: usable)
                    .offset(x: x(upper))
            }
            .frame(maxHeight: .infinity)
            .coordinateSpace(name: "track")
        }
        .frame(height: thumbSize + 2)
    }

    private func thumb(value: Binding<Double>, range: ClosedRange<Double>, name: String, usable: CGFloat) -> some View {
        let set = { (newValue: Double) in
            value.wrappedValue = min(max(newValue.rounded(), range.lowerBound), range.upperBound)
        }
        return Circle()
            .fill(.white)
            .overlay(Circle().stroke(.black.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 1.2, y: 0.5)
            .frame(width: thumbSize, height: thumbSize)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("track"))
                    .onChanged { drag in
                        set(Double((drag.location.x - thumbSize / 2) / usable) * 100)
                    }
            )
            .focusable()
            .onKeyPress(.leftArrow) { set(value.wrappedValue - 1); return .handled }
            .onKeyPress(.rightArrow) { set(value.wrappedValue + 1); return .handled }
            .accessibilityElement()
            .accessibilityLabel(name)
            .accessibilityValue("\(Int(value.wrappedValue)) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: set(value.wrappedValue + 1)
                case .decrement: set(value.wrappedValue - 1)
                @unknown default: break
                }
            }
    }
}
