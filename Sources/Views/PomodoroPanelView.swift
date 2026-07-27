import SwiftUI

struct PomodoroPanelView: View {
    @Environment(AppState.self) private var appState
    @State private var store = PomodoroStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    phasePicker
                    timerSurface
                    cycleProgress
                    durationSettings
                    behaviorSettings
                }
                .padding(14)
            }

            Divider()
            footer
        }
        .frame(minWidth: 300, idealWidth: 340, maxWidth: 460, maxHeight: .infinity)
        .background(.bar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Pomodoro", systemImage: "timer")
                .font(.headline)

            Spacer()

            if store.isRunning {
                Text(store.remainingText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(phaseColor)
            }

            PanelIconButton(systemName: "xmark", help: "Hide Pomodoro") {
                appState.hidePomodoroTool()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var phasePicker: some View {
        Picker("Session type", selection: Binding(
            get: { store.phase },
            set: { store.selectPhase($0) }
        )) {
            ForEach(PomodoroPhase.allCases) { phase in
                Text(phase.compactTitle).tag(phase)
            }
        }
        .pickerStyle(.segmented)
        .disabled(store.isRunning)
        .help(store.isRunning ? "Pause or reset before changing session type" : "Choose a session type")
    }

    private var timerSurface: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.14), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: store.progress)
                    .stroke(
                        phaseColor,
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: store.progress)

                VStack(spacing: 5) {
                    Image(systemName: store.phase.systemImage)
                        .font(.title3)
                        .foregroundStyle(phaseColor)
                    Text(store.remainingText)
                        .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                    Text(store.phase.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 188, height: 188)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(store.phase.title), \(store.remainingText) remaining")

            Text(store.sessionDetail)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                Button {
                    if store.isRunning {
                        store.pause()
                    } else {
                        store.start()
                    }
                } label: {
                    Label(
                        store.isRunning ? "Pause" : (store.progress > 0 ? "Resume" : "Start"),
                        systemImage: store.isRunning ? "pause.fill" : "play.fill"
                    )
                    .frame(minWidth: 72)
                }
                .buttonStyle(.borderedProminent)
                .tint(phaseColor)

                Button {
                    store.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .help("Reset this session")

                Button {
                    store.skip()
                } label: {
                    Image(systemName: "forward.end.fill")
                }
                .buttonStyle(.bordered)
                .help("Skip to the next session")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }

    private var cycleProgress: some View {
        VStack(spacing: 8) {
            HStack {
                Label(
                    "\(store.completedFocusSessions) completed",
                    systemImage: "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Text("4-session cycle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index < store.focusSessionsInCycle
                            ? phaseColor.opacity(0.82)
                            : Color.secondary.opacity(0.16))
                        .frame(height: 7)
                }
            }
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(store.focusSessionsInCycle) of 4 focus sessions in this cycle")
    }

    private var durationSettings: some View {
        GroupBox("Durations") {
            VStack(spacing: 10) {
                durationStepper(
                    title: "Focus",
                    value: Binding(
                        get: { store.focusMinutes },
                        set: { store.focusMinutes = $0 }
                    ),
                    range: 5...90,
                    step: 5
                )
                Divider()
                durationStepper(
                    title: "Short break",
                    value: Binding(
                        get: { store.shortBreakMinutes },
                        set: { store.shortBreakMinutes = $0 }
                    ),
                    range: 1...30,
                    step: 1
                )
                Divider()
                durationStepper(
                    title: "Long break",
                    value: Binding(
                        get: { store.longBreakMinutes },
                        set: { store.longBreakMinutes = $0 }
                    ),
                    range: 5...60,
                    step: 5
                )
            }
            .padding(.top, 4)
        }
        .disabled(store.isRunning)
    }

    private var behaviorSettings: some View {
        VStack(spacing: 10) {
            Toggle("Auto-start next session", isOn: Binding(
                get: { store.autoStartNextSession },
                set: { store.autoStartNextSession = $0 }
            ))
            Toggle("Play sound when complete", isOn: Binding(
                get: { store.playCompletionSound },
                set: { store.playCompletionSound = $0 }
            ))
        }
        .toggleStyle(.switch)
        .font(.callout)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: store.isRunning ? "timer" : "info.circle")
                .foregroundStyle(store.isRunning ? phaseColor : Color.secondary)
            Text(store.isRunning
                ? "Timer continues when this panel is hidden."
                : "Choose a session and press Start.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func durationStepper(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue) min")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var phaseColor: Color {
        switch store.phase {
        case .focus: .red
        case .shortBreak: .green
        case .longBreak: .blue
        }
    }
}
