import AppKit
import CoreAudio
import SwiftUI

private func l(_ key: String, _ arguments: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return String(format: format, locale: Locale.current, arguments: arguments)
}

private struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let name: String
    let uid: String
}

private struct AudioApp: Identifiable, Hashable {
    let id: pid_t
    let name: String
    let bundleID: String
}

private func propertyAddress(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var address = propertyAddress(selector, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let result = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }
    return result == noErr ? ids : []
}

private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var address = propertyAddress(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let result = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
    return result == noErr ? (value?.takeRetainedValue() as String? ?? "") : ""
}

private func isOutput(_ id: AudioObjectID) -> Bool {
    var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
    let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, memory) == noErr else { return false }
    return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).contains { $0.mNumberChannels > 0 }
}

private func outputDevices() -> [AudioDevice] {
    objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        .filter(isOutput)
        .map { AudioDevice(id: $0, name: stringProperty($0, kAudioObjectPropertyName), uid: stringProperty($0, kAudioDevicePropertyDeviceUID)) }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

private func defaultOutputID() -> AudioObjectID? {
    var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr ? id : nil
}

private func runningApps() -> [AudioApp] {
    NSWorkspace.shared.runningApplications.compactMap { app in
        guard app.activationPolicy == .regular, let name = app.localizedName else { return nil }
        return AudioApp(id: app.processIdentifier, name: name, bundleID: app.bundleIdentifier ?? "")
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

private func nominalRate(_ id: AudioObjectID) -> Double? {
    var address = propertyAddress(kAudioDevicePropertyNominalSampleRate, scope: kAudioDevicePropertyScopeOutput)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr ? rate : nil
}

private func setNominalRate(_ rate: Double, on id: AudioObjectID) -> Bool {
    for scope in [kAudioObjectPropertyScopeGlobal, kAudioDevicePropertyScopeOutput] {
        var address = propertyAddress(kAudioDevicePropertyNominalSampleRate, scope: scope)
        var value = Float64(rate)
        if AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value) == noErr { return true }
    }
    return false
}

private func supportsNominalRate(_ rate: Double, on id: AudioObjectID) -> Bool? {
    for scope in [kAudioObjectPropertyScopeGlobal, kAudioDevicePropertyScopeOutput] {
        var address = propertyAddress(kAudioDevicePropertyAvailableNominalSampleRates, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { continue }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ranges) == noErr else { continue }
        return ranges.contains { rate >= $0.mMinimum - 0.5 && rate <= $0.mMaximum + 0.5 }
    }
    return nil
}

private func preferHighBitDepth(on id: AudioObjectID) -> Int? {
    let rate = nominalRate(id) ?? 48_000
    for stream in objectIDs(id, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput) {
        var address = propertyAddress(kAudioStreamPropertyAvailablePhysicalFormats)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(stream, &address, 0, nil, &size) == noErr, size > 0 else { continue }
        var formats = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(), count: Int(size) / MemoryLayout<AudioStreamRangedDescription>.size)
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &formats) == noErr else { continue }
        for bits in [32, 24, 16] {
            guard var format = formats.first(where: {
                $0.mFormat.mFormatID == kAudioFormatLinearPCM && $0.mFormat.mBitsPerChannel == UInt32(bits) &&
                rate >= $0.mSampleRateRange.mMinimum && rate <= $0.mSampleRateRange.mMaximum
            })?.mFormat else { continue }
            format.mSampleRate = rate
            var physical = propertyAddress(kAudioStreamPropertyPhysicalFormat)
            if AudioObjectSetPropertyData(stream, &physical, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &format) == noErr { return bits }
        }
    }
    return nil
}

private enum MusicRate {
    case playing(Double, String)
    case stopped
    case unavailable
    case error(String)
}

private func musicRate() -> MusicRate {
    let source = """
    tell application "Music"
        if player state is playing then
            try
                set currentSong to current track
                set trackKey to persistent ID of currentSong
                try
                    set trackRate to sample rate of currentSong
                on error
                    set trackRate to 0
                end try
                return "playing|" & (trackRate as text) & "|" & trackKey
            on error
                return "unavailable"
            end try
        else
            return "stopped"
        end if
    end tell
    """
    guard let script = NSAppleScript(source: source) else { return .error(l("script_compile_failed")) }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    if let error { return .error(error[NSAppleScript.errorMessage] as? String ?? l("automation_failed")) }
    guard let value = result.stringValue else { return .unavailable }
    if value == "stopped" { return .stopped }
    let fields = value.split(separator: "|", omittingEmptySubsequences: false)
    guard fields.count == 3, fields[0] == "playing", let rate = Double(fields[1]) else { return .unavailable }
    return .playing(rate, String(fields[2]))
}

private func rateText(_ rate: Double) -> String {
    String(format: "%.1f kHz", rate / 1000)
}

private let musicLogPredicate = "process == \"Music\" AND (eventMessage CONTAINS \"Created new AudioQueue\" OR eventMessage CONTAINS \"activeFormat\")"

private func loggedSampleRate(_ line: String) -> Double? {
    guard line.contains("Created new AudioQueue") || line.contains("activeFormat"),
          let range = line.range(of: #"sampleRate:\s*[0-9]+"#, options: .regularExpression),
          let digits = line[range].split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
          let number = Double(digits) else { return nil }
    let rate = number < 1_000 ? number * 1_000 : number
    return rate >= 8_000 && rate <= 768_000 ? rate : nil
}

@MainActor private final class MusicFormatMonitor {
    var onRate: ((Double) -> Void)?
    var onHistoricalRate: ((Double) -> Void)?
    private var process: Process?
    private var output: Pipe?
    private var buffer = ""

    func start() {
        guard process == nil else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = ["stream", "--style", "compact", "--predicate", musicLogPredicate]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.receive(text) }
        }
        do {
            try task.run()
            process = task
            output = pipe
            loadRecent()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    private func loadRecent() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            task.arguments = ["show", "--last", "15m", "--style", "compact", "--predicate", musicLogPredicate]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8),
                  let rate = output.split(separator: "\n").compactMap({ loggedSampleRate(String($0)) }).last else { return }
            DispatchQueue.main.async { self?.onHistoricalRate?(rate) }
        }
    }

    func stop() {
        output?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        output = nil
        buffer = ""
    }

    private func receive(_ text: String) {
        buffer += text
        while let end = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<end])
            buffer.removeSubrange(...end)
            if let rate = loggedSampleRate(line) { onRate?(rate) }
        }
    }
}

@MainActor private final class AudioModel: ObservableObject {
    @Published var apps: [AudioApp] = []
    @Published var devices: [AudioDevice] = []
    @Published var selectedApp: pid_t = 0
    @Published var selectedDevice: AudioObjectID = 0
    @Published var routing = false
    @Published var following = false
    @Published var maximumBitDepth = false
    @Published var routeStatus = l("select_app_device")
    @Published var rateStatus = l("off")
    @Published var bitDepthStatus = l("off")
    @Published var trackRate = "—"
    @Published var deviceRate = "—"
    @Published var switchingRate = false
    @Published var lastError: String?

    private var routeProcess: Process?
    private var refreshTimer: Timer?
    private var rateTimer: Timer?
    private var checkingRate = false
    private var pendingRateChange: (rate: Double, source: MusicRate)?
    private var pendingBitDepthChange = false
    private let formatMonitor = MusicFormatMonitor()
    private var latestLogRate: (rate: Double, at: Date)?
    private var trackKey: String?
    private var trackChangedAt = Date.distantPast

    var device: AudioDevice? { devices.first { $0.id == selectedDevice } }
    var app: AudioApp? { apps.first { $0.id == selectedApp } }

    func start() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func shutdown() {
        refreshTimer?.invalidate()
        rateTimer?.invalidate()
        formatMonitor.stop()
        routeProcess?.terminate()
    }

    func refresh() {
        let oldApp = selectedApp
        let oldDevice = selectedDevice
        apps = runningApps()
        devices = outputDevices()
        if !apps.contains(where: { $0.id == oldApp }) { selectedApp = apps.first(where: { $0.bundleID == "com.apple.Music" })?.id ?? apps.first?.id ?? 0 }
        if !devices.contains(where: { $0.id == oldDevice }) {
            selectedDevice = defaultOutputID().flatMap { preferred in devices.first { $0.id == preferred }?.id } ?? devices.first?.id ?? 0
        }
        if let device { deviceRate = nominalRate(device.id).map(rateText) ?? "—" } else { deviceRate = "—" }
    }

    func toggleRoute() {
        if routing {
            routeProcess?.terminate()
            routeStatus = l("route_stopping")
            return
        }
        guard let app, let device else { return }
        guard let helper = Bundle.main.path(forResource: "audio-route", ofType: nil, inDirectory: "Helpers") else {
            lastError = l("helper_missing")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["route", "--app", String(app.id), "--device", device.uid]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                for message in line.split(separator: "\n") {
                    let text = String(message).trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.hasPrefix("Waiting for ") {
                        self.routeStatus = l("route_waiting", app.name)
                    } else if text.hasPrefix("Routing ") {
                        self.routeStatus = l("route_active", app.name, device.name)
                    } else if text == "App exited or output device disconnected." {
                        self.routeStatus = l("route_ended")
                    } else if text.hasPrefix("No Core Audio process appeared") {
                        self.routeStatus = l("route_no_audio")
                    } else if !text.isEmpty && !text.hasPrefix("Frames:") {
                        self.routeStatus = l("route_error_detail", text)
                    }
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.routing = false
                self.routeProcess = nil
                if let pending = self.pendingRateChange {
                    self.pendingRateChange = nil
                    self.routeStatus = l("route_resuming")
                    if self.following {
                        self.applyRate(pending.rate, source: pending.source) {
                            self.switchingRate = false
                            self.toggleRoute()
                        }
                    } else {
                        self.switchingRate = false
                        self.toggleRoute()
                    }
                } else if self.pendingBitDepthChange {
                    self.pendingBitDepthChange = false
                    self.applyMaximumBitDepth()
                    self.switchingRate = false
                    self.toggleRoute()
                } else if self.routeStatus == l("route_stopping") {
                    self.routeStatus = l("route_stopped")
                }
            }
        }
        do {
            try process.run()
            routeProcess = process
            routing = true
            routeStatus = l("route_waiting", app.name)
        } catch {
            lastError = l("route_start_failed", error.localizedDescription)
        }
    }

    func toggleFollow() {
        if following {
            following = false
            rateTimer?.invalidate()
            rateTimer = nil
            formatMonitor.stop()
            latestLogRate = nil
            trackKey = nil
            rateStatus = l("off")
            trackRate = "—"
            return
        }
        guard device != nil else { return }
        following = true
        formatMonitor.onRate = { [weak self] rate in
            self?.latestLogRate = (rate, Date())
            self?.checkMusicRate()
        }
        formatMonitor.onHistoricalRate = { [weak self] rate in
            guard let self, self.following, self.latestLogRate == nil else { return }
            self.latestLogRate = (rate, Date())
            self.checkMusicRate()
        }
        formatMonitor.start()
        rateStatus = l("reading_music")
        checkMusicRate()
        rateTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.checkMusicRate() }
        }
    }

    func toggleMaximumBitDepth() {
        if maximumBitDepth {
            maximumBitDepth = false
            bitDepthStatus = l("bit_depth_off")
            return
        }
        guard device != nil else { return }
        maximumBitDepth = true
        if routing {
            switchingRate = true
            pendingBitDepthChange = true
            bitDepthStatus = l("bit_depth_pausing_route")
            routeProcess?.terminate()
        } else {
            applyMaximumBitDepth()
        }
    }

    private func applyMaximumBitDepth() {
        guard maximumBitDepth, let device else { return }
        if let bits = preferHighBitDepth(on: device.id) {
            bitDepthStatus = l("bit_depth_selected", bits)
        } else {
            bitDepthStatus = l("bit_depth_unavailable")
        }
    }

    private func checkMusicRate() {
        guard following, !checkingRate, !switchingRate, let device else { return }
        checkingRate = true
        let id = device.id
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let trackRate = musicRate()
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkingRate = false
                guard self.following, self.selectedDevice == id else { return }
                if case .error(let message) = trackRate {
                    self.trackRate = "—"
                    self.rateStatus = l("music_read_failed", message)
                    return
                }
                let target: Double
                switch trackRate {
                case .playing(let rate, let key):
                    if self.trackKey != key {
                        self.trackKey = key
                        self.trackChangedAt = Date()
                    }
                    if let logged = self.latestLogRate,
                       logged.at >= self.trackChangedAt.addingTimeInterval(-2.5) {
                        target = logged.rate
                        self.trackRate = l("rate_from_playback", rateText(logged.rate))
                    } else if Date().timeIntervalSince(self.trackChangedAt) < 2 {
                        self.trackRate = l("detecting")
                        self.rateStatus = l("waiting_playback_format")
                        return
                    } else if rate > 0 {
                        target = rate
                        self.trackRate = l("rate_from_metadata", rateText(rate))
                    } else {
                        self.trackRate = l("unavailable")
                        self.rateStatus = l("music_rate_unavailable")
                        return
                    }
                case .stopped:
                    self.trackRate = l("not_playing")
                    target = 48_000
                case .unavailable:
                    if let logged = self.latestLogRate,
                       Date().timeIntervalSince(logged.at) < 30 {
                        target = logged.rate
                        self.trackRate = l("rate_from_playback", rateText(logged.rate))
                    } else {
                        self.trackRate = l("unavailable")
                        self.rateStatus = l("music_rate_unavailable")
                        return
                    }
                case .error: return
                }
                let current = nominalRate(id)
                if self.routing, current.map({ abs($0 - target) >= 0.5 }) ?? true {
                    self.switchingRate = true
                    self.pendingRateChange = (target, trackRate)
                    self.rateStatus = l("pausing_for_rate", rateText(target))
                    self.routeProcess?.terminate()
                    return
                }
                self.applyRate(target, source: trackRate)
            }
        }
    }

    private func applyRate(_ target: Double, source: MusicRate, completion: (() -> Void)? = nil) {
        guard let device else { completion?(); return }
        let id = device.id
        if supportsNominalRate(target, on: id) == false {
            rateStatus = l("rate_unsupported", rateText(target))
            completion?()
            return
        }
        let current = nominalRate(id)
        let rateChanged = current.map({ abs($0 - target) >= 0.5 }) ?? true
        if rateChanged {
            guard setNominalRate(target, on: id) else {
                rateStatus = l("rate_set_failed", rateText(target))
                completion?()
                return
            }
        }
        // HAL may report the previous value briefly after accepting a format change.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            if self.maximumBitDepth && rateChanged { self.applyMaximumBitDepth() }
            guard let actual = nominalRate(id) else {
                self.rateStatus = l("device_rate_read_failed")
                completion?()
                return
            }
            self.deviceRate = rateText(actual)
            if abs(actual - target) >= 0.5 {
                self.rateStatus = l("rate_mismatch", rateText(actual), rateText(target))
            } else if case .stopped = source {
                self.rateStatus = l("music_stopped_set", rateText(actual))
            } else {
                self.rateStatus = l("music_following_set", rateText(actual))
            }
            completion?()
        }
    }
}

private struct AudioCardStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            configuration.label
                .font(.system(.subheadline, design: .default).weight(.semibold))
                .foregroundStyle(.secondary)
            configuration.content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.055)))
    }
}

private struct ContentView: View {
    @StateObject private var model = AudioModel()

    private let accent = Color(red: 0.32, green: 0.83, blue: 0.73)

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.path").font(.title2).foregroundStyle(accent)
                    Text("AudioFlow").font(.system(size: 23, weight: .semibold, design: .rounded))
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle().stroke(accent.opacity(0.08), lineWidth: 1).frame(width: 210, height: 210)
                    Circle().stroke(accent.opacity(0.16), lineWidth: 1).frame(width: 164, height: 164)
                    Image(systemName: model.routing ? "waveform" : "hifispeaker.fill")
                        .font(.system(size: 64, weight: .ultraLight)).foregroundStyle(accent)
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 10) {
                    Text(l("current_format")).font(.caption).foregroundStyle(.white.opacity(0.55))
                    Text(model.deviceRate).font(.system(size: 37, weight: .light, design: .rounded))
                        .monospacedDigit().foregroundStyle(accent)
                    Text(model.device?.name ?? "—").font(.subheadline).foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Label(model.routeStatus, systemImage: model.routing ? "circle.fill" : "circle")
                    .font(.caption).foregroundStyle(model.routing ? accent : .white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(30).frame(width: 280)
            .frame(maxHeight: .infinity)
            .foregroundStyle(.white)
            .background(LinearGradient(colors: [Color(red: 0.08, green: 0.17, blue: 0.20), Color(red: 0.04, green: 0.09, blue: 0.13)], startPoint: .topLeading, endPoint: .bottomTrailing))

            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(l("app_routing")).font(.system(size: 26, weight: .semibold))
                        Text(l("subtitle")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help(l("refresh_help"))
                }
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(l("app"), systemImage: "music.note").font(.caption).foregroundStyle(.secondary)
                        Picker(l("app"), selection: $model.selectedApp) {
                            ForEach(model.apps) { app in Text(app.name).tag(app.id) }
                        }.labelsHidden().disabled(model.routing)
                    }
                    HStack { Spacer(); Image(systemName: "arrow.down").foregroundStyle(.tertiary); Spacer() }
                    VStack(alignment: .leading, spacing: 8) {
                        Label(l("device"), systemImage: "hifispeaker").font(.caption).foregroundStyle(.secondary)
                        Picker(l("device"), selection: $model.selectedDevice) {
                            ForEach(model.devices) { device in Text(device.name).tag(device.id) }
                        }.labelsHidden().disabled(model.routing || model.following || model.maximumBitDepth)
                    }
                    Button { model.toggleRoute() } label: {
                        HStack {
                            Image(systemName: model.routing ? "stop.fill" : "play.fill")
                            Text(model.routing ? l("stop_routing") : l("start_routing"))
                        }.frame(maxWidth: .infinity).padding(.vertical, 5)
                    }.buttonStyle(.borderedProminent)
                        .disabled(model.app == nil || model.device == nil || model.switchingRate)
                }.padding(22)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))

                VStack(alignment: .leading, spacing: 18) {
                    Text(l("output_format")).font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(l("follow_rate"), isOn: Binding(get: { model.following }, set: { _ in model.toggleFollow() }))
                            .disabled(model.device == nil || model.switchingRate)
                        Text(l("current_track", model.trackRate)).font(.caption).foregroundStyle(.secondary)
                        Text(model.rateStatus).font(.caption).foregroundStyle(.secondary)
                        Text(l("sample_rate_note")).font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(l("maximum_bit_depth"), isOn: Binding(get: { model.maximumBitDepth }, set: { _ in model.toggleMaximumBitDepth() }))
                            .disabled(model.device == nil || model.switchingRate)
                        Text(model.bitDepthStatus).font(.caption).foregroundStyle(.secondary)
                        Text(l("bit_depth_note")).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.toggleStyle(.switch)
                Spacer(minLength: 0)
            }.padding(32).frame(width: 500)
        }
        .frame(width: 780, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Color(red: 0.16, green: 0.46, blue: 0.44))
        .controlSize(.large)
        .onAppear { model.start() }
        .onDisappear { model.shutdown() }
        .alert("AudioFlow", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button(l("ok")) { model.lastError = nil }
        } message: { Text(model.lastError ?? "") }
    }
}

@main struct AudioFlowApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowResizability(.contentSize)
    }
}
