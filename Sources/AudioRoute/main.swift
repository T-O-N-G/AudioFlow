import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization
import Darwin

private let stopRequested = Atomic<Bool>(false)

private func address(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var property = address(selector, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let status = ids.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!)
    }
    return status == noErr ? ids : []
}

private func scalarProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               initial: T) -> T? {
    var property = address(selector, scope: scope)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0)
    }
    return status == noErr ? value : nil
}

private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var property = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0)
    }
    guard status == noErr, let value else { return "" }
    return value.takeRetainedValue() as String
}

private func isOutputDevice(_ id: AudioObjectID) -> Bool {
    var property = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr, size > 0 else { return false }
    let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, memory) == noErr else { return false }
    let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
    return buffers.contains { $0.mNumberChannels > 0 }
}

private struct OutputDevice {
    let id: AudioObjectID
    let name: String
    let uid: String
}

private struct RunningApp {
    let pid: pid_t
    let name: String
    let bundleID: String
}

private func devices() -> [OutputDevice] {
    objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { id in
        guard isOutputDevice(id) else { return nil }
        return OutputDevice(id: id, name: stringProperty(id, kAudioObjectPropertyName),
                            uid: stringProperty(id, kAudioDevicePropertyDeviceUID))
    }
}

private func apps() -> [RunningApp] {
    NSWorkspace.shared.runningApplications.compactMap { app in
        guard app.activationPolicy == .regular, let name = app.localizedName else { return nil }
        return RunningApp(pid: app.processIdentifier, name: name, bundleID: app.bundleIdentifier ?? "")
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

private func audioProcess(for pid: pid_t) -> AudioObjectID? {
    for id in objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
        if scalarProperty(id, kAudioProcessPropertyPID, initial: pid_t(0)) == pid { return id }
    }
    return nil
}

private func select<T>(_ entries: [T], query: String, fields: (T) -> [String]) -> T? {
    let exact = entries.filter { fields($0).contains { $0.caseInsensitiveCompare(query) == .orderedSame } }
    if exact.count == 1 { return exact[0] }
    if exact.count > 1 { return nil }
    let partial = entries.filter { fields($0).contains { $0.localizedCaseInsensitiveContains(query) } }
    return partial.count == 1 ? partial[0] : nil
}

private final class RingBuffer {
    let capacity: UInt64
    let bytesPerFrame: Int
    let bufferCount: Int
    let data: [UnsafeMutableRawPointer]
    let readFrame = Atomic<UInt64>(0)
    let writeFrame = Atomic<UInt64>(0)
    let capturedFrames = Atomic<UInt64>(0)
    let playedFrames = Atomic<UInt64>(0)
    let droppedFrames = Atomic<UInt64>(0)
    let silentFrames = Atomic<UInt64>(0)

    init(format: AudioStreamBasicDescription) {
        let capacity = UInt64(format.mSampleRate * 2)
        let bytesPerFrame = Int(format.mBytesPerFrame)
        let bufferCount = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            ? Int(format.mChannelsPerFrame) : 1
        self.capacity = capacity
        self.bytesPerFrame = bytesPerFrame
        self.bufferCount = bufferCount
        self.data = (0..<bufferCount).map { _ in
            let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(capacity) * bytesPerFrame, alignment: 16)
            memory.initializeMemory(as: UInt8.self, repeating: 0, count: Int(capacity) * bytesPerFrame)
            return memory
        }
    }

    deinit { data.forEach { $0.deallocate() } }

    @inline(__always)
    private func copy(to destination: UnsafeMutableRawPointer, from source: UnsafeRawPointer,
                      ring: UnsafeMutableRawPointer, at frame: UInt64, count: Int, writing: Bool) {
        let position = Int(frame % capacity)
        let first = min(count, Int(capacity) - position)
        if writing {
            ring.advanced(by: position * bytesPerFrame).copyMemory(from: source, byteCount: first * bytesPerFrame)
            if count > first {
                ring.copyMemory(from: source.advanced(by: first * bytesPerFrame),
                                byteCount: (count - first) * bytesPerFrame)
            }
        } else {
            destination.copyMemory(from: ring.advanced(by: position * bytesPerFrame),
                                   byteCount: first * bytesPerFrame)
            if count > first {
                destination.advanced(by: first * bytesPerFrame).copyMemory(from: ring,
                                                                          byteCount: (count - first) * bytesPerFrame)
            }
        }
    }

    func capture(_ list: UnsafePointer<AudioBufferList>?) {
        guard let list else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard buffers.count == bufferCount, let first = buffers.first else { return }
        let frames = Int(first.mDataByteSize) / bytesPerFrame
        guard frames > 0, frames <= Int(capacity),
              buffers.allSatisfy({ $0.mData != nil && Int($0.mDataByteSize) >= frames * bytesPerFrame }) else { return }
        let write = writeFrame.load(ordering: .relaxed)
        let read = readFrame.load(ordering: .acquiring)
        if write - read + UInt64(frames) > capacity {
            _ = droppedFrames.wrappingAdd(UInt64(frames), ordering: .relaxed)
            return
        }
        for index in 0..<bufferCount {
            let source = UnsafeRawPointer(buffers[index].mData!)
            copy(to: data[index], from: source, ring: data[index], at: write, count: frames, writing: true)
        }
        writeFrame.store(write + UInt64(frames), ordering: .releasing)
        _ = capturedFrames.wrappingAdd(UInt64(frames), ordering: .relaxed)
    }

    func render(_ list: UnsafeMutablePointer<AudioBufferList>?, frames: UInt32) {
        guard let list else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard buffers.count == bufferCount,
              buffers.allSatisfy({ $0.mData != nil && Int($0.mDataByteSize) >= Int(frames) * bytesPerFrame }) else { return }
        let read = readFrame.load(ordering: .relaxed)
        let write = writeFrame.load(ordering: .acquiring)
        let available = min(Int(frames), Int(write - read))
        for index in 0..<bufferCount {
            copy(to: buffers[index].mData!, from: data[index], ring: data[index],
                 at: read, count: available, writing: false)
        }
        readFrame.store(read + UInt64(available), ordering: .releasing)
        _ = playedFrames.wrappingAdd(UInt64(available), ordering: .relaxed)
        if available < Int(frames) {
            _ = silentFrames.wrappingAdd(UInt64(Int(frames) - available), ordering: .relaxed)
        }
    }
}

nonisolated(unsafe) private let inputCallback: AudioDeviceIOProc = { _, _, input, _, _, _, client in
    if let client { Unmanaged<RingBuffer>.fromOpaque(client).takeUnretainedValue().capture(input) }
    return noErr
}

nonisolated(unsafe) private let outputCallback: AURenderCallback = { client, _, _, _, frames, output in
    Unmanaged<RingBuffer>.fromOpaque(client).takeUnretainedValue().render(output, frames: frames)
    return noErr
}

private func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw RouteError.message("\(operation) failed (OSStatus \(status), 0x\(String(UInt32(bitPattern: status), radix: 16))).") }
}

private enum RouteError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let text) = self { text } else { "Unknown error" } }
}

private func route(app: RunningApp, device: OutputDevice) throws {
    var tap = AudioObjectID(kAudioObjectUnknown)
    var aggregate = AudioObjectID(kAudioObjectUnknown)
    var inputProc: AudioDeviceIOProcID?
    var outputUnit: AudioComponentInstance?
    var inputStarted = false
    var outputStarted = false
    var ring: RingBuffer?
    defer {
        if outputStarted, let outputUnit { AudioOutputUnitStop(outputUnit) }
        if inputStarted, let inputProc { AudioDeviceStop(aggregate, inputProc) }
        if let inputProc { AudioDeviceDestroyIOProcID(aggregate, inputProc) }
        if let outputUnit { AudioUnitUninitialize(outputUnit); AudioComponentInstanceDispose(outputUnit) }
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        if let ring {
            fputs("Frames: \(ring.capturedFrames.load(ordering: .relaxed)) captured, " +
                  "\(ring.playedFrames.load(ordering: .relaxed)) played, " +
                  "\(ring.droppedFrames.load(ordering: .relaxed)) dropped, " +
                  "\(ring.silentFrames.load(ordering: .relaxed)) silent.\n", stderr)
        }
    }

    fputs("Waiting for \(app.name) (PID \(app.pid)) to use Core Audio. Start playback if needed...\n", stderr)
    var process: AudioObjectID?
    for _ in 0..<300 {
        if stopRequested.load(ordering: .relaxed) { break }
        process = audioProcess(for: app.pid)
        if process != nil || kill(app.pid, 0) != 0 { break }
        usleep(100_000)
    }
    guard let process else { throw RouteError.message("No Core Audio process appeared for this app within 30 seconds.") }

    let description = CATapDescription(stereoMixdownOfProcesses: [process])
    description.name = "audio-route process tap"
    description.isPrivate = true
    description.muteBehavior = CATapMuteBehavior.mutedWhenTapped
    try check(AudioHardwareCreateProcessTap(description, &tap), "Create process tap")

    let tapUID = stringProperty(tap, kAudioTapPropertyUID)
    let aggregateDescription: [String: Any] = [
        kAudioAggregateDeviceNameKey: "audio-route capture",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]]
    ]
    try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate),
              "Create aggregate device")

    guard let format: AudioStreamBasicDescription = scalarProperty(tap, kAudioTapPropertyFormat,
                                                                    initial: AudioStreamBasicDescription()),
          format.mFormatID == kAudioFormatLinearPCM, format.mBytesPerFrame > 0,
          format.mSampleRate > 0, format.mChannelsPerFrame > 0, format.mChannelsPerFrame <= 8 else {
        throw RouteError.message("Unsupported tap PCM format.")
    }
    ring = RingBuffer(format: format)
    let refCon = Unmanaged.passUnretained(ring!).toOpaque()

    var component = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                              componentSubType: kAudioUnitSubType_HALOutput,
                                              componentManufacturer: kAudioUnitManufacturer_Apple,
                                              componentFlags: 0, componentFlagsMask: 0)
    guard let found = AudioComponentFindNext(nil, &component) else {
        throw RouteError.message("HAL output component is unavailable.")
    }
    try check(AudioComponentInstanceNew(found, &outputUnit), "Open output unit")
    guard let outputUnit else { throw RouteError.message("Output unit is unavailable.") }
    var enabled: UInt32 = 1
    try check(AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Output, 0, &enabled, UInt32(MemoryLayout.size(ofValue: enabled))),
              "Enable output")
    var destination = device.id
    try check(AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &destination, UInt32(MemoryLayout.size(ofValue: destination))),
              "Select output device")
    var outputFormat = format
    try check(AudioUnitSetProperty(outputUnit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Input, 0, &outputFormat, UInt32(MemoryLayout.size(ofValue: outputFormat))),
              "Set output PCM format")
    var callback = AURenderCallbackStruct(inputProc: outputCallback, inputProcRefCon: refCon)
    try check(AudioUnitSetProperty(outputUnit, kAudioUnitProperty_SetRenderCallback,
                                   kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout.size(ofValue: callback))),
              "Set output callback")
    try check(AudioUnitInitialize(outputUnit), "Initialize output unit")
    try check(AudioDeviceCreateIOProcID(aggregate, inputCallback, refCon, &inputProc), "Create capture callback")
    try check(AudioDeviceStart(aggregate, inputProc), "Start capture")
    inputStarted = true
    usleep(80_000)
    try check(AudioOutputUnitStart(outputUnit), "Start output")
    outputStarted = true
    print("Routing \(app.name) → \(device.name). Press Ctrl-C to stop.")
    fflush(stdout)
    while !stopRequested.load(ordering: .relaxed) {
        sleep(1)
        if kill(app.pid, 0) != 0 || !isOutputDevice(device.id) {
            fputs("App exited or output device disconnected.\n", stderr)
            break
        }
    }
}

private func usage() {
    fputs("Usage:\n  audio-route list-apps\n  audio-route list-devices\n" +
          "  audio-route route --app NAME|BUNDLE_ID|PID --device NAME|UID|ID\n", stderr)
}

private func run() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments {
    case ["list-apps"]:
        let running = apps()
        print("PID\tAPP\tAUDIO\tBUNDLE ID")
        for app in running {
            print("\(app.pid)\t\(app.name)\t\(audioProcess(for: app.pid) == nil ? "-" : "yes")\t\(app.bundleID)")
        }
        if running.isEmpty { fputs("No GUI apps are visible. Run from your logged-in macOS session.\n", stderr) }
        return 0
    case ["list-devices"]:
        let outputs = devices()
        print("ID\tOUTPUT DEVICE\tUID")
        for device in outputs { print("\(device.id)\t\(device.name)\t\(device.uid)") }
        if outputs.isEmpty { fputs("No output devices are visible. Run from your logged-in macOS session.\n", stderr) }
        return 0
    default:
        guard arguments.count == 5, arguments[0] == "route" else { usage(); return 2 }
        var appQuery: String?, deviceQuery: String?
        for index in stride(from: 1, to: arguments.count, by: 2) {
            switch arguments[index] {
            case "--app": appQuery = arguments[index + 1]
            case "--device": deviceQuery = arguments[index + 1]
            default: usage(); return 2
            }
        }
        guard let appQuery, !appQuery.isEmpty, let deviceQuery, !deviceQuery.isEmpty else { usage(); return 2 }
        guard let app = select(apps(), query: appQuery,
                               fields: { [String($0.pid), $0.name, $0.bundleID] }) else {
            fputs("App not found or ambiguous: \(appQuery). Run list-apps.\n", stderr)
            return 2
        }
        guard let device = select(devices(), query: deviceQuery,
                                  fields: { [String($0.id), $0.name, $0.uid] }) else {
            fputs("Output device not found or ambiguous: \(deviceQuery). Run list-devices.\n", stderr)
            return 2
        }
        signal(SIGINT) { _ in stopRequested.store(true, ordering: .relaxed) }
        signal(SIGTERM) { _ in stopRequested.store(true, ordering: .relaxed) }
        do { try route(app: app, device: device); return 0 }
        catch { fputs("\(error)\n", stderr); return 1 }
    }
}

exit(run())
