import AVFoundation
import AppKit
import Combine
import ServiceManagement

/// Everything the main window shows, published from the controller.
@MainActor
final class AppState: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case status = "Status"
        case settings = "Settings"
        case history = "History"
        case dictionary = "Dictionary"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .status: "waveform.circle"
            case .settings: "gearshape"
            case .history: "clock"
            case .dictionary: "character.book.closed"
            }
        }
    }

    enum ModelStatus: Equatable {
        case checking, downloading, ready, unavailable(String)
        var description: String {
            switch self {
            case .checking: "Checking speech model…"
            case .downloading: "Downloading speech model…"
            case .ready: "Speech model ready"
            case .unavailable(let why): "Speech model unavailable: \(why)"
            }
        }
        var isReady: Bool { self == .ready }
    }

    @Published var selectedSection: Section = .status
    @Published var dictationState: DictationController.State = .idle
    @Published var modelStatus: ModelStatus = .checking
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var hotkeyReady = false
    @Published var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var inputDevices: [AudioInputDevice] = AudioDevices.inputDevices()
    @Published var selectedInputUID: String = AudioDevices.preferredUID {
        didSet { AudioDevices.preferredUID = selectedInputUID }
    }
    @Published var polishing: (available: Bool, description: String) = TranscriptCleaner.modelStatus()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var polishingEnabled: Bool = UserDefaults.standard.object(forKey: "MurmurCleanupEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(polishingEnabled, forKey: "MurmurCleanupEnabled") }
    }
    @Published var readyAfterMs: Int?
    @Published var lastProblem: String?

    private var permissionTimer: Timer?
    private var deviceObserver: AnyObject?

    init() {
        deviceObserver = AudioDevices.observeDeviceChanges { [weak self] in
            Task { @MainActor in self?.refreshDevices() }
        }
    }

    /// Polls permission state while the window is visible; the system gives
    /// no notification when the user flips a toggle in System Settings.
    func startPolling() {
        guard permissionTimer == nil else { return }
        refresh()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        polishing = TranscriptCleaner.modelStatus()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func refreshDevices() {
        inputDevices = AudioDevices.inputDevices()
    }

    var recordingDeviceName: String {
        AudioDevices.resolveRecordingDevice()?.name ?? "No microphone found"
    }

    var isReadyToDictate: Bool {
        hotkeyReady && microphoneStatus == .authorized && modelStatus.isReady
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.info("Murmur: launch at login toggle failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func requestMicrophone() {
        Task {
            _ = await AudioRecorder.requestPermission()
            refresh()
        }
    }
}
