import SwiftUI
import AVFoundation
import AppKit

public enum CaptureMode {
    case photo, video
}

public struct CameraDevice: Identifiable {
    public let id: String
    public let device: AVCaptureDevice
    
    public init(device: AVCaptureDevice) {
        self.device = device
        self.id = device.uniqueID
    }
}

@MainActor
public final class CameraSessionController: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published public private(set) var devices: [CameraDevice] = []
    @Published public var selectedDeviceID: String? {
        didSet {
            Task { @MainActor in
                await configureSession()
            }
        }
    }
    @Published public private(set) var isAuthorized: Bool = false
    @Published public private(set) var isRunning: Bool = false
    @Published public var captureMode: CaptureMode = .photo
    @Published public private(set) var lastPhotoData: Data?
    @Published public private(set) var lastVideoURL: URL?
    
    public let session = AVCaptureSession()
    public let photoOutput = AVCapturePhotoOutput()
    public let movieOutput = AVCaptureMovieFileOutput()
    
    private var currentInput: AVCaptureDeviceInput?
    
    public override init() {
        super.init()
        session.sessionPreset = .high
    }
    
    public func requestAuthorization() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                self.isAuthorized = granted
                if granted {
                    self.refreshDevices()
                } else {
                    self.devices = []
                    self.selectedDeviceID = nil
                }
            }
        }
    }
    
    public func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.externalUnknown, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        let found = discovery.devices.map { CameraDevice(device: $0) }
        DispatchQueue.main.async {
            self.devices = found
            if self.selectedDeviceID == nil || !found.contains(where: { $0.id == self.selectedDeviceID }) {
                self.selectedDeviceID = found.first?.id
            }
        }
    }
    
    @MainActor
    public func start() {
        guard isAuthorized else { return }
        guard !session.isRunning else {
            self.isRunning = true
            return
        }
        Task {
            await configureSession()
            session.startRunning()
            DispatchQueue.main.async {
                self.isRunning = true
            }
        }
    }
    
    @MainActor
    private func configureSession() async {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        
        // Remove existing inputs
        if let input = currentInput {
            session.removeInput(input)
            currentInput = nil
        }
        
        guard let selectedID = selectedDeviceID,
              let camDevice = devices.first(where: { $0.id == selectedID })?.device else {
            return
        }
        
        do {
            let input = try AVCaptureDeviceInput(device: camDevice)
            if session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
            }
        } catch {
            // ignore input error
        }
        
        // Add photoOutput
        if !session.outputs.contains(where: { $0 == photoOutput }) {
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
        }
        
        // Add movieOutput
        if !session.outputs.contains(where: { $0 == movieOutput }) {
            if session.canAddOutput(movieOutput) {
                session.addOutput(movieOutput)
            }
        }
    }
    
    @MainActor
    public func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
        isRunning = false
    }
    
    public func capturePhoto() {
        guard isAuthorized else { return }
        guard captureMode == .photo else { return }
        
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
    
    public func toggleRecording() {
        guard isAuthorized else { return }
        guard captureMode == .video else { return }
        
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        } else {
            let tempDir = FileManager.default.temporaryDirectory
            let dateStr = Self.dateFormatter.string(from: Date())
            let filename = "video-\(dateStr).mov"
            let outputURL = tempDir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }
            movieOutput.startRecording(to: outputURL, recordingDelegate: self)
        }
    }
    
    // MARK: AVCapturePhotoCaptureDelegate
    
    public func photoOutput(_ output: AVCapturePhotoOutput,
                            didFinishProcessingPhoto photo: AVCapturePhoto,
                            error: Error?) {
        if let error = error {
            // ignore for now
            return
        }
        guard let data = photo.fileDataRepresentation() else { return }
        DispatchQueue.main.async {
            self.lastPhotoData = data
            self.lastVideoURL = nil
        }
    }
    
    // MARK: AVCaptureFileOutputRecordingDelegate
    
    public func fileOutput(_ output: AVCaptureFileOutput,
                           didFinishRecordingTo outputFileURL: URL,
                           from connections: [AVCaptureConnection],
                           error: Error?) {
        DispatchQueue.main.async {
            if error == nil {
                self.lastVideoURL = outputFileURL
                self.lastPhotoData = nil
            }
        }
    }
    
    // Date formatter for filenames
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

public struct CameraPreviewView: NSViewRepresentable {
    @ObservedObject public var controller: CameraSessionController
    
    public init(controller: CameraSessionController) {
        self.controller = controller
    }
    
    public func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let previewLayer = AVCaptureVideoPreviewLayer(session: controller.session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = .zero
        
        view.wantsLayer = true
        view.layer = previewLayer
        
        context.coordinator.previewLayer = previewLayer
        return view
    }
    
    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let previewLayer = context.coordinator.previewLayer else { return }
        previewLayer.session = controller.session
        previewLayer.frame = nsView.bounds
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    public class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}

public struct WebcamCaptureSheet: View {
    @Binding var isPresented: Bool
    
    var onPhoto: (Data, String, String) -> Void
    var onVideo: (URL, String, String) -> Void
    
    @StateObject private var controller = CameraSessionController()
    
    public init(isPresented: Binding<Bool>,
                onPhoto: @escaping (Data, String, String) -> Void,
                onVideo: @escaping (URL, String, String) -> Void) {
        self._isPresented = isPresented
        self.onPhoto = onPhoto
        self.onVideo = onVideo
    }
    
    public var body: some View {
        VStack(spacing: 12) {
            if !controller.isAuthorized {
                VStack(spacing: 8) {
                    Text("Camera access is required. Please grant permission in System Preferences → Security & Privacy → Privacy → Camera.")
                        .multilineTextAlignment(.center)
                        .padding()
                    Button("Request Access") {
                        controller.requestAuthorization()
                    }
                }
            } else {
                VStack(spacing: 12) {
                    HStack {
                        Picker("Camera", selection: $controller.selectedDeviceID) {
                            ForEach(controller.devices) { device in
                                Text(device.device.localizedName).tag(device.id as String?)
                            }
                        }
                        .frame(minWidth: 150)
                        Picker("Mode", selection: $controller.captureMode) {
                            Text("Photo").tag(CaptureMode.photo)
                            Text("Video").tag(CaptureMode.video)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 160)
                        Spacer()
                    }
                    .padding(.horizontal)
                    
                    CameraPreviewView(controller: controller)
                        .frame(minHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.horizontal)
                    
                    HStack {
                        if controller.captureMode == .photo {
                            Button("Capture Photo") {
                                controller.capturePhoto()
                            }
                            .keyboardShortcut(.defaultAction)
                        } else {
                            Button(controller.movieOutput.isRecording ? "Stop Recording" : "Start Recording") {
                                controller.toggleRecording()
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                        Spacer()
                        Button("Cancel") {
                            isPresented = false
                        }
                        Button("Use This") {
                            useThis()
                        }
                        .disabled(!hasCapturedData)
                    }
                    .padding(.horizontal)
                }
                .onAppear {
                    controller.requestAuthorization()
                    controller.refreshDevices()
                    controller.start()
                }
                .onDisappear {
                    controller.stop()
                }
            }
        }
        .frame(minWidth: 480, minHeight: 380)
        .padding()
    }
    
    private var hasCapturedData: Bool {
        switch controller.captureMode {
        case .photo:
            return controller.lastPhotoData != nil
        case .video:
            return controller.lastVideoURL != nil
        }
    }
    
    private func useThis() {
        switch controller.captureMode {
        case .photo:
            if let data = controller.lastPhotoData {
                let filename = "photo-\(CameraSessionController.dateFormatter.string(from: Date())).jpg"
                onPhoto(data, filename, "image/jpeg")
                isPresented = false
            }
        case .video:
            if let url = controller.lastVideoURL {
                let filename = "video-\(CameraSessionController.dateFormatter.string(from: Date())).mov"
                onVideo(url, filename, "video/quicktime")
                isPresented = false
            }
        }
    }
}
