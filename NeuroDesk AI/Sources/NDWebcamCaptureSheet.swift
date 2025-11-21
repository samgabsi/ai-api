#if false
import SwiftUI
import AVFoundation
import Combine

struct NDWebcamCaptureSheet: View {
    @Binding var isPresented: Bool
    let onPhoto: (Data, String, String) -> Void
    let onVideo: (URL, String, String) -> Void

    @State private var controller = NDCCameraController()
    @State private var isRecording = false
    @State private var authorizationStatus: AVAuthorizationStatus = .notDetermined
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(spacing: 12) {
            Text("Webcam").font(.headline)
            ZStack {
                NDCCameraPreviewView(controller: controller)
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(8)
                if let err = errorMessage {
                    Text(err).foregroundColor(.red).padding()
                }
            }
            .frame(minWidth: 560, minHeight: 360)

            HStack(spacing: 12) {
                Button(isRecording ? "Stop Recording" : "Start Recording") {
                    if isRecording {
                        controller.stopRecording()
                    } else {
                        controller.startRecording()
                    }
                    isRecording.toggle()
                }
                .disabled(authorizationStatus != .authorized)

                Button("Take Photo") {
                    controller.capturePhoto()
                }
                .disabled(authorizationStatus != .authorized || isRecording)

                Spacer()
                Button("Close") { isPresented = false }
            }
            .padding(.top, 8)
        }
        .padding()
        .onAppear {
            Task { await setup() }
        }
        .onDisappear {
            controller.stopSession()
        }
        .onReceive(controller.photoPublisher) { data in
            let filename = timestampedFilename(prefix: "photo", ext: "jpg")
            onPhoto(data, filename, "image/jpeg")
        }
        .onReceive(controller.videoFinishedPublisher) { url in
            let filename = url.deletingPathExtension().lastPathComponent + ".mov"
            onVideo(url, filename, "video/quicktime")
        }
    }

    private func setup() async {
        let status = await NDCCameraController.requestAuthorization()
        await MainActor.run {
            authorizationStatus = status
            if status == .authorized {
                do {
                    try controller.configureSession()
                    controller.startSession()
                } catch {
                    errorMessage = error.localizedDescription
                }
            } else if status == .denied || status == .restricted {
                errorMessage = "Camera access denied. Enable it in System Settings > Privacy & Security > Camera."
            }
        }
    }

    private func timestampedFilename(prefix: String, ext: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        return "\(prefix)_\(df.string(from: Date())).\(ext)"
    }
}

// MARK: - Camera Preview

private struct NDCCameraPreviewView: NSViewRepresentable {
    let controller: NDCCameraController

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        controller.attachPreview(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Nothing to update continuously
    }
}

// MARK: - Camera Controller

final class NDCCameraController: NSObject, ObservableObject {
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    // Publishers
    let photoPublisher = PassthroughSubject<Data, Never>()
    let videoFinishedPublisher = PassthroughSubject<URL, Never>()

    private let queue = DispatchQueue(label: "ndc.camera.session.queue")

    static func requestAuthorization() async -> AVAuthorizationStatus {
        await withCheckedContinuation { cont in
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                cont.resume(returning: .authorized)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    cont.resume(returning: granted ? .authorized : .denied)
                }
            case .denied:
                cont.resume(returning: .denied)
            case .restricted:
                cont.resume(returning: .restricted)
            @unknown default:
                cont.resume(returning: .denied)
            }
        }
    }

    func configureSession() throws {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video) else {
            throw NSError(domain: "NDCCamera", code: -1, userInfo: [NSLocalizedDescriptionKey: "No camera available"]) }
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) { session.addInput(input) }

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }

        session.commitConfiguration()
    }

    func attachPreview(to view: NSView) {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.wantsLayer = true
        view.layer?.addSublayer(layer)
        previewLayer = layer

        // Keep layer sized to view
        view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self, weak view] _ in
            guard let view = view else { return }
            self?.previewLayer?.frame = view.bounds
        }
    }

    func startSession() {
        queue.async { [weak self] in self?.session.startRunning() }
    }

    func stopSession() {
        queue.async { [weak self] in self?.session.stopRunning() }
    }

    func capturePhoto() {
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func startRecording() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    func stopRecording() {
        movieOutput.stopRecording()
    }
}

// MARK: - Delegates

extension NDCCameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            print("Photo capture error: \(error)")
            return
        }
        guard let data = photo.fileDataRepresentation() else { return }
        photoPublisher.send(data)
    }
}

extension NDCCameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let error = error {
            print("Video recording error: \(error)")
            return
        }
        videoFinishedPublisher.send(outputFileURL)
    }
}
#endif

