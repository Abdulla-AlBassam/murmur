import AVFoundation
import AppKit
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            List(AppState.Section.allCases, selection: $appState.selectedSection) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            switch appState.selectedSection {
            case .status: StatusView(appState: appState)
            case .settings: SettingsView(appState: appState)
            case .history: HistoryView(store: .shared)
            case .dictionary: DictionaryView(store: .shared)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

// MARK: - Status

struct StatusView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: stateSymbol)
                        .font(.system(size: 34))
                        .foregroundStyle(appState.dictationState == .recording ? .red : .accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stateTitle).font(.title2.weight(.semibold))
                        Text(stateDetail).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                if let problem = appState.lastProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("Setup") {
                StatusRow(
                    title: "Accessibility",
                    detail: appState.accessibilityGranted
                        ? "Granted. Murmur can see the fn key and paste text."
                        : "Needed to watch the fn key and to paste into the focused app.",
                    ok: appState.accessibilityGranted
                ) {
                    if !appState.accessibilityGranted {
                        Button("Open System Settings") {
                            Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                        }
                    }
                }
                StatusRow(
                    title: "Microphone",
                    detail: microphoneDetail,
                    ok: appState.microphoneStatus == .authorized
                ) {
                    switch appState.microphoneStatus {
                    case .notDetermined:
                        Button("Allow Microphone") { appState.requestMicrophone() }
                    case .denied, .restricted:
                        Button("Open System Settings") {
                            Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                        }
                    default:
                        EmptyView()
                    }
                }
                StatusRow(
                    title: "Speech model",
                    detail: appState.modelStatus.description,
                    ok: appState.modelStatus.isReady,
                    busy: appState.modelStatus == .checking || appState.modelStatus == .downloading
                ) { EmptyView() }
                StatusRow(
                    title: "Polishing",
                    detail: appState.polishing.available
                        ? appState.polishing.description
                        : "\(appState.polishing.description). Dictation is inserted as recognised.",
                    ok: appState.polishing.available,
                    warningOnly: true
                ) {
                    if !appState.polishing.available {
                        Button("Apple Intelligence Settings") {
                            Self.open("x-apple.systempreferences:com.apple.Siri-Settings.extension")
                        }
                    }
                }
                StatusRow(
                    title: "🌐 key",
                    detail: "Set “Press 🌐 key to” to “Do Nothing” in Keyboard settings so macOS stays out of the way.",
                    ok: true, warningOnly: true
                ) {
                    Button("Keyboard Settings") {
                        Self.open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
                    }
                }
            }

            Section("This session") {
                LabeledContent("Recording from", value: appState.recordingDeviceName)
                if let ms = appState.readyAfterMs {
                    LabeledContent("Ready to dictate", value: "\(String(format: "%.1f", Double(ms) / 1000)) s after launch")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Status")
    }

    private var stateSymbol: String {
        switch appState.dictationState {
        case .idle: appState.isReadyToDictate ? "waveform.circle" : "waveform.slash"
        case .starting: "waveform.circle"
        case .recording: "waveform.circle.fill"
        case .processing: "sparkles"
        }
    }

    private var stateTitle: String {
        switch appState.dictationState {
        case .idle: appState.isReadyToDictate ? "Hold fn to dictate" : "Finish setup to dictate"
        case .starting: "Starting…"
        case .recording: "Listening…"
        case .processing: "Polishing…"
        }
    }

    private var stateDetail: String {
        if !appState.hotkeyReady { return "Waiting for Accessibility permission." }
        if appState.microphoneStatus != .authorized { return "Waiting for microphone permission." }
        if !appState.modelStatus.isReady { return appState.modelStatus.description }
        return "Speak while holding fn; release to insert the text into the focused app."
    }

    private var microphoneDetail: String {
        switch appState.microphoneStatus {
        case .authorized: "Granted."
        case .notDetermined: "macOS will ask the first time you dictate, or allow it now."
        case .denied: "Denied. Allow Murmur under Privacy & Security → Microphone."
        case .restricted: "Restricted by a system policy."
        @unknown default: "Unknown."
        }
    }

    static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

private struct StatusRow<Actions: View>: View {
    let title: String
    let detail: String
    let ok: Bool
    var busy = false
    var warningOnly = false
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: ok ? "checkmark.circle.fill" : (warningOnly ? "exclamationmark.circle.fill" : "xmark.circle.fill"))
                        .foregroundStyle(ok ? .green : (warningOnly ? .orange : .red))
                }
            }
            .frame(width: 18)
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            actions()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("Dictation") {
                Toggle("Polish dictation with Apple Intelligence", isOn: $appState.polishingEnabled)
                Text("Removes fillers, applies spoken corrections and adds punctuation. It never adds, answers or rewrites; if the model strays, the plain transcript is used instead.")
                    .font(.callout).foregroundStyle(.secondary)
                if !appState.polishing.available {
                    Label(appState.polishing.description, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.orange)
                }
            }

            Section("Microphone") {
                Picker("Record from", selection: $appState.selectedInputUID) {
                    Text("Built-in microphone (recommended)").tag("")
                    ForEach(appState.inputDevices.filter { !$0.isBuiltIn }) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                Text(microphoneHint)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: { appState.setLaunchAtLogin($0) }))
                LabeledContent("Push to talk", value: "Hold fn (🌐)")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { appState.refreshDevices() }
    }

    private var microphoneHint: String {
        let selected = appState.inputDevices.first { $0.uid == appState.selectedInputUID }
        if let selected, selected.isBluetooth {
            return "Bluetooth headset microphones make macOS switch the headset to its low-quality call profile while recording, so music will sound dull until you release fn. Your playback device is never changed."
        }
        if !appState.selectedInputUID.isEmpty, selected == nil {
            return "That microphone is not connected; the built-in microphone is used until it returns."
        }
        return "Murmur only opens the microphone while fn is held and never changes the system default input or output."
    }
}
