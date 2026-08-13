import SwiftUI
import SweepCore

/// The optional protection switch that sits beside the Scan button.
///
/// Deliberately *not* an `NSSwitch` or a `Toggle`: a system switch beside a large capsule CTA
/// reads as a settings control that wandered onto the home screen. This is built from the same
/// vocabulary the rest of Sweep already uses. A capsule of the same height as the Scan button,
/// the same corner geometry, the same restrained palette: so the pair reads as one scanning
/// control group with a clear primary and secondary.
///
/// Hierarchy is intentional: Scan stays the filled pink CTA; Protection is a quieter capsule
/// that gains a tint only when it is on. It never competes with Scan for attention.
struct ProtectionToggle: View {
    @Binding var isOn: Bool
    var isEnabled: Bool = true

    @State private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Matches the Scan button's `.controlSize(.large)` height so the two capsules align exactly.
    private let height: CGFloat = 32

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isOn ? "shield.fill" : "shield")
                    .font(.system(size: 12, weight: .semibold))
                    // Symbol replacement rather than a crossfade: the shield fills, which reads
                    // as the state change itself rather than as decoration.
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)

                Text("Protection")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isOn ? .primary : .secondary)

                // The state read-out carries the meaning, so the control is understandable
                // without relying on colour alone.
                Text(isOn ? "On" : "Off")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                    .frame(width: 22, alignment: .leading)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 14)
            .frame(height: height)
            .background {
                Capsule()
                    .fill(isOn ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12))
            }
            .overlay {
                Capsule()
                    .strokeBorder(isOn ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.22),
                                  lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        // Understated press feedback, in the same register as the rest of the app: a small
        // settle, not a bounce.
        .scaleEffect(isPressed ? 0.97 : 1)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: isOn)
        .animation(reduceMotion ? nil : .smooth(duration: 0.12), value: isPressed)
        .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
            guard isEnabled else { return }
            isPressed = pressing
        }, perform: {})
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Protection scan")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(isOn
            ? "Scans also check for malware. Double-tap to turn off."
            : "Scans skip the malware check. Double-tap to turn on.")
        .accessibilityAddTraits(.isButton)
        .help(isOn
            ? "Scans also check for malware. This adds a few minutes."
            : "Scans skip the malware check.")
    }
}
