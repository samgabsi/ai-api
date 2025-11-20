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
    @Published public private(set) var isRecording: Bool = false
    
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
        // Update floating preview after capture
        DispatchQueue.main.async {
            self.isRecording = false
        }
    }
    
    public func toggleRecording() {
        guard isAuthorized else { return }
        guard captureMode == .video else { return }
        
        if movieOutput.isRecording {
            movieOutput.stopRecording()
            DispatchQueue.main.async {
                self.isRecording = false
            }
        } else {
            let tempDir = FileManager.default.temporaryDirectory
            let dateStr = Self.dateFormatter.string(from: Date())
            let filename = "video-\(dateStr).mov"
            let outputURL = tempDir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }
            movieOutput.startRecording(to: outputURL, recordingDelegate: self)
            DispatchQueue.main.async {
                self.isRecording = true
            }
        }
    }
    
    // MARK: AVCapturePhotoCaptureDelegate
    
}

extension CameraSessionController: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput,
                            didFinishProcessingPhoto photo: AVCapturePhoto,
                            error: Error?) {
        if let _ = error {
            // ignore for now
            return
        }
        guard let data = photo.fileDataRepresentation() else { return }
        DispatchQueue.main.async {
            self.lastPhotoData = data
            self.lastVideoURL = nil
        }
    }
}

// MARK: AVCaptureFileOutputRecordingDelegate

extension CameraSessionController {
    public func fileOutput(_ output: AVCaptureFileOutput,
                           didFinishRecordingTo outputFileURL: URL,
                           from connections: [AVCaptureConnection],
                           error: Error?) {
        DispatchQueue.main.async {
            if error == nil {
                self.lastVideoURL = outputFileURL
                self.lastPhotoData = nil
            }
            self.isRecording = false
        }
    }
}

// Date formatter for filenames
extension CameraSessionController {
    fileprivate static let dateFormatter: DateFormatter = {
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

// Floating window hosting utility
public struct FloatingPreviewWindow: Identifiable {
    public let id = UUID()
    public let window: NSWindow
}

public final class FloatingPreviewController: NSObject, ObservableObject {
    @Published public var isShown: Bool = false
    private var hostingController: NSHostingController<AnyView>?
    private var windowRef: NSWindow?
    
    public func show<Content: View>(@ViewBuilder content: () -> Content) {
        let view = AnyView(content())
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Camera Preview"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.setFrame(NSRect(x: 100, y: 100, width: 360, height: 240), display: true)
        win.makeKeyAndOrderFront(nil)
        self.hostingController = host
        self.windowRef = win
        self.isShown = true
    }
    
    public func hide() {
        windowRef?.orderOut(nil)
        hostingController = nil
        windowRef = nil
        isShown = false
    }
    
    public func update<Content: View>(@ViewBuilder content: () -> Content) {
        hostingController?.rootView = AnyView(content())
    }
}

public struct LegacyWebcamCaptureSheet: SwiftUI.View {
    @Binding var isPresented: Bool
    
    var onPhoto: (Data, String, String) -> Void
    var onVideo: (URL, String, String) -> Void
    
    @StateObject private var controller = CameraSessionController()
    @StateObject private var floating = FloatingPreviewController()
    
    public init(isPresented: Binding<Bool>,
                onPhoto: @escaping (Data, String, String) -> Void,
                onVideo: @escaping (URL, String, String) -> Void) {
        self._isPresented = isPresented
        self.onPhoto = onPhoto
        self.onVideo = onVideo
    }
    
    public var body: some SwiftUI.View {
        VStack(spacing: 12) {
            if !controller.isAuthorized {
                VStack(spacing: 8) {
                    SwiftUI.Text("Camera access is required. Please grant permission in System Preferences → Security & Privacy → Privacy → Camera.")
                        .multilineTextAlignment(.center)
                        .padding()
                    SwiftUI.Button("Request Access") {
                        controller.requestAuthorization()
                    }
                }
            } else {
                VStack(spacing: 12) {
                    HStack {
                        SwiftUI.Picker("Camera", selection: $controller.selectedDeviceID) {
                            ForEach(controller.devices) { device in
                                SwiftUI.Text(device.device.localizedName).tag(device.id as String?)
                            }
                        }
                        .frame(minWidth: 150)
                        SwiftUI.Picker("Mode", selection: $controller.captureMode) {
                            SwiftUI.Text("Photo").tag(CaptureMode.photo)
                            SwiftUI.Text("Video").tag(CaptureMode.video)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 160)
                        
                        SwiftUI.Button(floating.isShown ? "Detach Preview" : "Attach Preview") {
                            if !floating.isShown {
                                floating.show {
                                    previewStack
                                }
                            } else {
                                floating.hide()
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    
                    inlinePreview
                        .frame(minHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.horizontal)
                    
                    HStack {
                        if controller.captureMode == .photo {
                            SwiftUI.Button("Capture Photo") {
                                controller.capturePhoto()
                                if floating.isShown {
                                    floating.update { previewStack }
                                }
                            }
                            .keyboardShortcut(.defaultAction)
                        } else {
                            SwiftUI.Button(controller.movieOutput.isRecording ? "Stop Recording" : "Start Recording") {
                                controller.toggleRecording()
                                if floating.isShown {
                                    floating.update { previewStack }
                                }
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                        Spacer()
                        SwiftUI.Button("Cancel") {
                            isPresented = false
                        }
                        SwiftUI.Button("Use This") {
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
                    floating.hide()
                }
                .onChange(of: controller.isRecording) { _ in
                    if floating.isShown {
                        floating.update { previewStack }
                    }
                }
                .onChange(of: controller.captureMode) { _ in
                    if floating.isShown {
                        floating.update { previewStack }
                    }
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
    
    // The previewStack view used for both inline and floating preview
    private var previewStack: some SwiftUI.View {
        ZStack(alignment: .topLeading) {
            CameraPreviewView(controller: controller)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
            
            previewOverlay
                .padding(8)
        }
    }
    
    // Inline preview reuse
    private var inlinePreview: some SwiftUI.View {
        previewStack
    }
    
    // Overlay showing LIVE red dot and mode, plus caption
    private var previewOverlay: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if controller.isRecording || controller.isRunning {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                    SwiftUI.Text("LIVE")
                        .font(.caption).bold()
                        .foregroundColor(.red)
                }
                SwiftUI.Text(modeText)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.leading, (controller.isRecording || controller.isRunning) ? 0 : 16)
                Spacer()
            }
            SwiftUI.Text("This is exactly what will be sent to ChatGPT when you capture.")
                .font(.caption2)
                .foregroundColor(Color.white.opacity(0.7))
                .padding(.top, 2)
        }
        .padding(6)
        .background(Color.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }
    
    private var modeText: String {
        switch controller.captureMode {
        case .photo:
            return "Photo"
        case .video:
            return "Video"
        }
    }
}

