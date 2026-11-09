import AVFoundation
import CoreImage
import Photos
import VideoToolbox

final class CameraModel: NSObject, ObservableObject,
                         AVCaptureVideoDataOutputSampleBufferDelegate,
                         AVCaptureAudioDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()

    // UI state
    @Published var isRecording = false
    @Published var status = "Starting…"
    @Published var logEnabled = true {
        didSet { let v = logEnabled; videoQueue.async { self.logOn = v } }
    }
    @Published var manualExposure = false
    @Published var iso: Float = 100
    @Published var shutterDenominator: Double = 48
    @Published var whiteBalanceK: Float = 5200
    @Published var lockWhiteBalance = false
    @Published var lockFocus = false
    @Published var isoRange: ClosedRange<Float> = 25...800

    // Queues
    private let sessionQueue = DispatchQueue(label: "logcam.session")
    private let videoQueue = DispatchQueue(label: "logcam.video")   // video + audio callbacks and writer state

    // Capture
    private var device: AVCaptureDevice?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange   // 10-bit 4:2:0
    private var videoSize = CGSize(width: 1920, height: 1080)
    private var fps: Int32 = 24
    private var usingHLG = false

    // Processing + writer (touched only on videoQueue)
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let cubeFilter = LogCurve.makeFilter()
    private var logOn = true
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false

    // MARK: Setup

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { self.setStatus("Camera access denied"); return }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.sessionQueue.async { self.configure() }
            }
        }
    }

    private func setStatus(_ s: String) { DispatchQueue.main.async { self.status = s } }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
            session.commitConfiguration(); setStatus("No camera available"); return
        }
        session.addInput(input)
        device = dev

        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        // Pick a 10-bit format: prefer 4K, then 1080p; prefer ones that support HLG.
        let tenBit = dev.formats.filter {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == pixelFormat
        }
        func width(_ f: AVCaptureDevice.Format) -> Int32 { CMVideoFormatDescriptionGetDimensions(f.formatDescription).width }
        func supports24(_ f: AVCaptureDevice.Format) -> Bool {
            f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 24 && 24 <= $0.maxFrameRate }
        }
        let chosen = tenBit.filter { width($0) == 3840 && supports24($0) }.first
            ?? tenBit.filter { width($0) == 1920 && supports24($0) }.first
            ?? tenBit.first

        if let fmt = chosen {
            do {
                try dev.lockForConfiguration()
                dev.activeFormat = fmt
                if fmt.supportedColorSpaces.contains(.HLG_BT2020) {
                    dev.activeColorSpace = .HLG_BT2020
                    usingHLG = true
                }
                fps = supports24(fmt) ? 24 : 30
                dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: fps)
                dev.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: fps)
                dev.unlockForConfiguration()
                let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                videoSize = CGSize(width: Int(d.width), height: Int(d.height))
                DispatchQueue.main.async {
                    self.isoRange = fmt.minISO...fmt.maxISO
                    self.iso = min(max(100, fmt.minISO), fmt.maxISO)
                }
            } catch { setStatus("Could not configure format") }
        } else {
            setStatus("This device has no 10-bit capture format")
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        audioOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        session.commitConfiguration()
        session.startRunning()
        setStatus(chosen == nil ? "Running (8-bit fallback)"
                  : "\(Int(videoSize.width))x\(Int(videoSize.height)) \(fps)fps 10-bit\(usingHLG ? " HLG" : "")")
    }

    // MARK: Manual controls

    func applyExposure() {
        sessionQueue.async {
            guard let dev = self.device else { return }
            do {
                try dev.lockForConfiguration()
                if self.manualExposure {
                    let fmt = dev.activeFormat
                    var dur = CMTime(value: 1, timescale: CMTimeScale(self.shutterDenominator))
                    dur = max(fmt.minExposureDuration, min(dur, fmt.maxExposureDuration))
                    let isoClamped = min(max(self.iso, fmt.minISO), fmt.maxISO)
                    dev.setExposureModeCustom(duration: dur, iso: isoClamped, completionHandler: nil)
                } else {
                    dev.exposureMode = .continuousAutoExposure
                }
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    func applyWhiteBalance() {
        sessionQueue.async {
            guard let dev = self.device else { return }
            do {
                try dev.lockForConfiguration()
                if self.lockWhiteBalance {
                    let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: self.whiteBalanceK, tint: 0)
                    var g = dev.deviceWhiteBalanceGains(for: tt)
                    let m = dev.maxWhiteBalanceGain
                    g.redGain = min(max(g.redGain, 1), m)
                    g.greenGain = min(max(g.greenGain, 1), m)
                    g.blueGain = min(max(g.blueGain, 1), m)
                    dev.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
                } else {
                    dev.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    func applyFocus() {
        sessionQueue.async {
            guard let dev = self.device else { return }
            do {
                try dev.lockForConfiguration()
                dev.focusMode = self.lockFocus ? .locked : .continuousAutoFocus
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: Recording

    func toggleRecording() { isRecording ? stopRecording() : startRecording() }

    private func startRecording() {
        let size = videoSize
        let hlg = usingHLG
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogCam-\(Int(Date().timeIntervalSince1970)).mov")
        videoQueue.async {
            do {
                let w = try AVAssetWriter(url: url, fileType: .mov)

                var vSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoWidthKey: Int(size.width),
                    AVVideoHeightKey: Int(size.height),
                    AVVideoCompressionPropertiesKey: [
                        AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                        AVVideoAverageBitRateKey: size.width > 2000 ? 60_000_000 : 25_000_000
                    ]
                ]
                // With the log curve on, leave the file untagged so players don't apply HLG tone mapping;
                // you grade it with a LUT. With log off, tag it as normal HLG.
                if hlg && !self.logOn {
                    vSettings[AVVideoColorPropertiesKey] = [
                        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
                    ]
                }
                let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
                vIn.expectsMediaDataInRealTime = true
                vIn.transform = CGAffineTransform(rotationAngle: .pi / 2)   // portrait

                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: vIn,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: self.pixelFormat,
                        kCVPixelBufferWidthKey as String: Int(size.width),
                        kCVPixelBufferHeightKey as String: Int(size.height)
                    ])
                if w.canAdd(vIn) { w.add(vIn) }

                let aSettings = self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
                let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
                aIn.expectsMediaDataInRealTime = true
                if w.canAdd(aIn) { w.add(aIn) }

                guard w.startWriting() else { throw w.error ?? NSError(domain: "LogCam", code: 1) }

                self.writer = w
                self.videoInput = vIn
                self.audioInput = aIn
                self.adaptor = adaptor
                self.sessionStarted = false
                DispatchQueue.main.async { self.isRecording = true }
            } catch {
                self.setStatus("Recording failed: \(error.localizedDescription)")
            }
        }
    }

    private func stopRecording() {
        DispatchQueue.main.async { self.isRecording = false }
        videoQueue.async {
            guard let w = self.writer else { return }
            let vIn = self.videoInput, aIn = self.audioInput
            self.writer = nil; self.videoInput = nil; self.audioInput = nil; self.adaptor = nil
            self.sessionStarted = false
            vIn?.markAsFinished(); aIn?.markAsFinished()
            w.finishWriting {
                if w.status == .completed { self.saveToPhotos(w.outputURL) }
                else { self.setStatus("Save failed: \(w.error?.localizedDescription ?? "unknown")") }
            }
        }
    }

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { auth in
            guard auth == .authorized || auth == .limited else { self.setStatus("Photos access denied"); return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            }) { ok, err in
                try? FileManager.default.removeItem(at: url)
                self.setStatus(ok ? "Saved to Photos" : "Save failed: \(err?.localizedDescription ?? "")")
            }
        }
    }

    // MARK: Sample buffer delegate (video + audio, serial queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let w = writer, w.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if output === videoOutput {
            if !sessionStarted { w.startSession(atSourceTime: pts); sessionStarted = true }
            guard let vIn = videoInput, vIn.isReadyForMoreMediaData, let adaptor = adaptor,
                  let src = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            var image = CIImage(cvPixelBuffer: src)
            if logOn, let f = cubeFilter {
                f.setValue(image, forKey: kCIInputImageKey)
                if let out = f.outputImage { image = out }
            }

            var dst: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst)
            }
            guard let outBuf = dst else { return }
            ciContext.render(image, to: outBuf)
            adaptor.append(outBuf, withPresentationTime: pts)
        } else if output === audioOutput, sessionStarted,
                  let aIn = audioInput, aIn.isReadyForMoreMediaData {
            aIn.append(sampleBuffer)
        }
    }
}
