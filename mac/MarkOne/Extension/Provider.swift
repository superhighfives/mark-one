import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio
import os.log

let log = Logger(subsystem: "com.superhighfives.markone.camera", category: "extension")

/// Frame size and rate of the E-M5's movie stream.
let frameWidth: Int32 = 1920
let frameHeight: Int32 = 1080
let frameRate: Int32 = 30

/// Fixed so apps remember the camera between launches. markone-feed finds
/// the device by this UID.
let deviceUID = "5B2F6E1C-9A3D-4C8E-B0F1-4D2A7C6E8B10"
let sourceStreamUID = "5B2F6E1C-9A3D-4C8E-B0F1-4D2A7C6E8B11"
let sinkStreamUID = "5B2F6E1C-9A3D-4C8E-B0F1-4D2A7C6E8B12"

/// "1" while any app is using the camera, "0" otherwise. Mark One reads it
/// to start the E-M5 only when it's wanted.
let inUseProperty = CMIOExtensionProperty(rawValue: "4cc_used_glob_0000")


final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var source: SourceStream!
    private var sink: SinkStream!

    private let queue = DispatchQueue(label: "com.superhighfives.markone.camera.frames", qos: .userInteractive)
    private var placeholderTimer: DispatchSourceTimer?
    private var placeholder: CMSampleBuffer?
    private var sourceClients = 0
    private var sinkClient: CMIOExtensionClient?
    private var lastSinkFrame = Date.distantPast

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: UUID(uuidString: deviceUID)!,
                                     legacyDeviceID: deviceUID, source: self)

        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                       width: frameWidth, height: frameHeight, extensions: nil,
                                       formatDescriptionOut: &description)
        let duration = CMTime(value: 1, timescale: frameRate)
        let format = CMIOExtensionStreamFormat(formatDescription: description!, maxFrameDuration: duration,
                                               minFrameDuration: duration, validFrameDurations: nil)

        source = SourceStream(localizedName: localizedName, streamID: UUID(uuidString: sourceStreamUID)!,
                              format: format, device: self)
        sink = SinkStream(localizedName: "\(localizedName).Sink", streamID: UUID(uuidString: sinkStreamUID)!,
                          format: format, device: self)
        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            log.error("adding streams failed: \(error.localizedDescription)")
        }
        placeholder = makePlaceholder()
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel, inUseProperty] }

    private var inUseState: CMIOExtensionPropertyState<AnyObject> {
        CMIOExtensionPropertyState(value: (queue.sync { sourceClients } > 0 ? "1" : "0") as NSString)
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            result.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            result.model = "Mark One"
        }
        if properties.contains(inUseProperty) {
            result.setPropertyState(inUseState, forProperty: inUseProperty)
        }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}


    func startSource() {
        queue.async { [self] in
            sourceClients += 1
            if sourceClients == 1 { notifyInUse(true) }
            guard placeholderTimer == nil else { return }
            // Fill in with the placeholder whenever the feed is quiet.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(frameRate))
            timer.setEventHandler { [weak self] in
                guard let self, Date().timeIntervalSince(self.lastSinkFrame) > 0.5, let placeholder = self.placeholder else { return }
                self.send(placeholder)
            }
            timer.resume()
            placeholderTimer = timer
        }
    }

    func stopSource() {
        queue.async { [self] in
            sourceClients = max(0, sourceClients - 1)
            if sourceClients == 0 {
                notifyInUse(false)
                placeholderTimer?.cancel()
                placeholderTimer = nil
            }
        }
    }

    private func notifyInUse(_ inUse: Bool) {
        let state = CMIOExtensionPropertyState<AnyObject>(value: (inUse ? "1" : "0") as NSString)
        device.notifyPropertiesChanged([inUseProperty: state])
    }

    private func send(_ sample: CMSampleBuffer) {
        guard sourceClients > 0 else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        source.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: UInt64(now.seconds * Double(NSEC_PER_SEC)))
    }


    func startSink(client: CMIOExtensionClient) {
        queue.async { [self] in
            sinkClient = client
            consume(from: client)
        }
    }

    func stopSink() {
        queue.async { [self] in sinkClient = nil }
    }

    private func consume(from client: CMIOExtensionClient) {
        guard sinkClient === client else { return }
        sink.stream.consumeSampleBuffer(from: client) { [weak self] sample, sequence, _, _, error in
            guard let self else { return }
            self.queue.async {
                if let sample {
                    self.lastSinkFrame = Date()
                    self.send(sample)
                    let now = CMClockGetTime(CMClockGetHostTimeClock())
                    let output = CMIOExtensionScheduledOutput(sequenceNumber: sequence,
                                                              hostTimeInNanoseconds: UInt64(now.seconds * Double(NSEC_PER_SEC)))
                    self.sink.stream.notifyScheduledOutputChanged(output)
                } else if error != nil {
                    // Nothing queued yet; ask again shortly.
                    self.queue.asyncAfter(deadline: .now() + 0.005) { self.consume(from: client) }
                    return
                }
                self.consume(from: client)
            }
        }
    }

    /// A dark gray frame shown while no video is coming in.
    private func makePlaceholder() -> CMSampleBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(frameWidth), Int(frameHeight),
                                  kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes as CFDictionary,
                                  &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 0), 0x20,
               CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * Int(frameHeight))
        memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 1), 0x80,
               CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * Int(frameHeight) / 2)
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                     formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: frameRate),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                 formatDescription: format!, sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        return sample
    }
}


final class SourceStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let device: DeviceSource

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, device: DeviceSource) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = CMTime(value: 1, timescale: frameRate) }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws { device.startSource() }

    func stopStream() throws { device.stopSource() }
}

final class SinkStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let device: DeviceSource
    private var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, device: DeviceSource) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .sink,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = CMTime(value: 1, timescale: frameRate) }
        // Keep the queue short: a webcam should show the newest frame.
        if properties.contains(.streamSinkBufferQueueSize) { result.sinkBufferQueueSize = 1 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { result.sinkBuffersRequiredForStartup = 1 }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        guard let client else { return }
        device.startSink(client: client)
    }

    func stopStream() throws { device.stopSink() }
}


final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DeviceSource(localizedName: "Mark One")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            log.error("adding the device failed: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = "Mark One" }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
