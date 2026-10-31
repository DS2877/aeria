import SwiftUI

/// A focus-driven 4-digit PIN entry, styled for the 10-foot UI. Used to set a
/// Parental PIN and to unlock the adult-content toggle.
struct PINPadView: View {
    enum Purpose {
        /// Enter a PIN once; `verify` decides if it's accepted.
        case enter
        /// Choose a new PIN, entered twice to confirm.
        case create
    }

    let purpose: Purpose
    let heading: String
    /// Required for `.enter` — return true to accept the PIN.
    var verify: ((String) -> Bool)? = nil
    /// `.enter`: the accepted PIN. `.create`: the confirmed new PIN.
    let onDone: (String) -> Void
    var onCancel: () -> Void = {}

    @State private var entry = ""
    @State private var firstEntry: String?
    @State private var error: String?

    private let columns = Array(repeating: GridItem(.fixed(120), spacing: Metrics.space2), count: 3)

    private var prompt: String {
        if let error { return error }
        switch purpose {
        case .enter:  return "Enter your 4-digit PIN"
        case .create: return firstEntry == nil ? "Choose a 4-digit PIN" : "Enter it again to confirm"
        }
    }

    var body: some View {
        VStack(spacing: Metrics.space4) {
            VStack(spacing: Metrics.space1) {
                Text(heading).font(.dsTitle)
                Text(prompt)
                    .font(.dsBody)
                    .foregroundStyle(error == nil ? Palette.textSecondary : Palette.liveDot)
                    .animation(.easeInOut(duration: 0.15), value: prompt)
            }

            HStack(spacing: Metrics.space2) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(index < entry.count ? Palette.accent : Palette.surfaceElevated)
                        .frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(Palette.hairline))
                }
            }
            .padding(.vertical, Metrics.space2)
            .accessibilityElement()
            .accessibilityLabel("PIN entry")
            .accessibilityValue("\(entry.count) of 4 digits")

            LazyVGrid(columns: columns, spacing: Metrics.space2) {
                ForEach(1...9, id: \.self) { digit($0) }
                Color.clear.frame(width: 120, height: 120)
                digit(0)
                backspace
            }

            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
                .padding(.top, Metrics.space2)
        }
        .padding(Metrics.space6)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas.ignoresSafeArea())
        .onChange(of: entry) { _, value in
            guard value.count == 4 else { return }
            Task { await settle(value) }
        }
    }

    private func digit(_ n: Int) -> some View {
        Button {
            error = nil
            if entry.count < 4 { entry.append(String(n)) }
        } label: {
            Text("\(n)")
                .font(.system(size: 40, weight: .semibold))
                .frame(width: 120, height: 120)
        }
        .buttonStyle(.card)
        .accessibilityLabel("\(n)")
    }

    private var backspace: some View {
        Button {
            error = nil
            if !entry.isEmpty { entry.removeLast() }
        } label: {
            Image(systemName: "delete.left")
                .font(.system(size: 34, weight: .medium))
                .frame(width: 120, height: 120)
        }
        .buttonStyle(.card)
        .accessibilityLabel("Delete")
    }

    /// Handle a completed 4-digit entry. The tiny delay lets the 4th dot render
    /// before we clear or dismiss.
    @MainActor
    private func settle(_ pin: String) async {
        try? await Task.sleep(for: .milliseconds(120))

        switch purpose {
        case .enter:
            if verify?(pin) ?? true {
                onDone(pin)
            } else {
                error = "That PIN didn't match. Try again."
                entry = ""
            }

        case .create:
            if let first = firstEntry {
                if pin == first {
                    onDone(pin)
                } else {
                    error = "Those didn't match. Start again."
                    firstEntry = nil
                    entry = ""
                }
            } else {
                firstEntry = pin
                entry = ""
            }
        }
    }
}
