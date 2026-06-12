import SwiftUI

struct DictationOverlayView: View {
    let phase: GlobalDictationCoordinator.Phase
    let audioLevel: Float
    let partialTranscript: String
    let onCancel: () -> Void

    @State private var readyPulse = false
    @State private var successScale: CGFloat = 0.82

    private let barCount = 9

    var body: some View {
        HStack(spacing: 10) {
            leadingIndicator
            centerContent
            trailingAccessory
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(pillBackground)
        .onAppear {
            readyPulse = true
            if phase == .success {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                    successScale = 1
                }
            }
        }
        .onChange(of: phase) { _, newPhase in
            if case .success = newPhase {
                successScale = 0.82
                withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                    successScale = 1
                }
            }
        }
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        switch phase {
        case .ready:
            Circle()
                .strokeBorder(ContinuumVoicePalette.accent.opacity(0.35), lineWidth: 1.5)
                .background(Circle().fill(ContinuumVoicePalette.accent.opacity(0.12)))
                .frame(width: 18, height: 18)
                .scaleEffect(readyPulse ? 1.08 : 0.92)
                .opacity(readyPulse ? 1 : 0.55)
                .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: readyPulse)
        case .recording:
            Circle()
                .fill(ContinuumVoicePalette.recordingRed)
                .frame(width: 7, height: 7)
                .shadow(color: ContinuumVoicePalette.recordingRed.opacity(0.55), radius: 4)
        case .processing:
            ProcessingRingView()
                .frame(width: 18, height: 18)
        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(ContinuumVoicePalette.successGreen)
                .frame(width: 18, height: 18)
                .scaleEffect(successScale)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ContinuumVoicePalette.warning)
                .frame(width: 18, height: 18)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var centerContent: some View {
        switch phase {
        case .ready:
            Text("Double-tap Fn")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        case .recording:
            HStack(spacing: 10) {
                waveform
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .leading)
                } else {
                    Text("Listening…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
        case .processing:
            Text("Processing…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
        case .success:
            Text("Done")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        case .error(let message):
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(2)
                .frame(maxWidth: 200, alignment: .leading)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        switch phase {
        case .recording:
            HStack(spacing: 8) {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                Text("Esc")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
        case .ready:
            Text("Fn")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
        default:
            EmptyView()
        }
    }

    private var subtitle: String {
        partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var waveform: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(ContinuumVoicePalette.waveform)
                    .frame(width: 3, height: barHeight(for: index))
                    .animation(.easeOut(duration: 0.1), value: audioLevel)
            }
        }
        .frame(width: 42, height: 18, alignment: .center)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let base: CGFloat = 4
        let maxHeight: CGFloat = 16
        let weight = Float(index + 1) / Float(barCount + 1)
        let level = max(audioLevel, 0.1)
        return base + CGFloat(level * weight * 2.4) * (maxHeight - base)
    }

    private var pillBackground: some View {
        Capsule(style: .continuous)
            .fill(ContinuumVoicePalette.pillFill)
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(ContinuumVoicePalette.pillBorder, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

private enum ContinuumVoicePalette {
    static let accent = Color(red: 0.79, green: 0.45, blue: 0.35)
    static let recordingRed = Color(red: 0.95, green: 0.34, blue: 0.34)
    static let successGreen = Color(red: 0.42, green: 0.84, blue: 0.58)
    static let warning = Color(red: 0.98, green: 0.72, blue: 0.38)
    static let waveform = Color(red: 1.0, green: 0.90, blue: 0.86)
    static let pillFill = Color(red: 0.06, green: 0.06, blue: 0.07).opacity(0.88)
    static let pillBorder = Color.white.opacity(0.10)
}

private struct ProcessingRingView: View {
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.72)
            .stroke(
                ContinuumVoicePalette.accent,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
            )
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

#if DEBUG
struct DictationOverlayView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            DictationOverlayView(phase: .ready, audioLevel: 0, partialTranscript: "", onCancel: {})
            DictationOverlayView(phase: .recording, audioLevel: 0.6, partialTranscript: "hello world", onCancel: {})
            DictationOverlayView(phase: .error("Could not start dictation"), audioLevel: 0, partialTranscript: "", onCancel: {})
        }
        .padding(40)
        .background(Color.gray.opacity(0.25))
    }
}
#endif
