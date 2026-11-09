import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var cam = CameraModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PreviewView(session: cam.session).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text(cam.status).font(.caption.monospaced())
                    Spacer()
                    if cam.isRecording {
                        Label("REC", systemImage: "circle.fill").foregroundStyle(.red).font(.caption.bold())
                    }
                }
                .padding(.horizontal).padding(.top, 8)

                Spacer()

                VStack(spacing: 10) {
                    Toggle("Log curve (flat recording)", isOn: $cam.logEnabled)
                        .disabled(cam.isRecording)

                    Toggle("Manual exposure", isOn: $cam.manualExposure)
                        .onChange(of: cam.manualExposure) { _, _ in cam.applyExposure() }
                    if cam.manualExposure {
                        HStack { Text("ISO \(Int(cam.iso))").frame(width: 80, alignment: .leading)
                            Slider(value: $cam.iso, in: cam.isoRange).onChange(of: cam.iso) { _, _ in cam.applyExposure() } }
                        HStack { Text("1/\(Int(cam.shutterDenominator))").frame(width: 80, alignment: .leading)
                            Slider(value: $cam.shutterDenominator, in: 24...2000).onChange(of: cam.shutterDenominator) { _, _ in cam.applyExposure() } }
                    }

                    Toggle("Lock white balance", isOn: $cam.lockWhiteBalance)
                        .onChange(of: cam.lockWhiteBalance) { _, _ in cam.applyWhiteBalance() }
                    if cam.lockWhiteBalance {
                        HStack { Text("\(Int(cam.whiteBalanceK))K").frame(width: 80, alignment: .leading)
                            Slider(value: $cam.whiteBalanceK, in: 2500...8000).onChange(of: cam.whiteBalanceK) { _, _ in cam.applyWhiteBalance() } }
                    }

                    Toggle("Lock focus", isOn: $cam.lockFocus)
                        .onChange(of: cam.lockFocus) { _, _ in cam.applyFocus() }
                }
                .font(.footnote)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)

                Button(action: cam.toggleRecording) {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                        RoundedRectangle(cornerRadius: cam.isRecording ? 6 : 30)
                            .fill(.red)
                            .frame(width: cam.isRecording ? 30 : 58, height: cam.isRecording ? 30 : 58)
                    }
                }
                .padding(.vertical, 16)
            }
        }
        .onAppear { cam.start() }
    }
}

struct PreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
