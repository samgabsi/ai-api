import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

struct NDWebcamCaptureSheet: View {
    @Binding var isPresented: Bool
    var onPhoto: (Data, String, String) -> Void
    var onVideo: (URL, String, String) -> Void
    
    @State private var showPhotoCapture = false
    @State private var showVideoCapture = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Capture or Choose Media")
                .font(.title2)
                .bold()
            
            Text("You can capture a new photo or choose an existing image or video file.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            
            Button("Capture Photo…") {
                showPhotoCapture = true
            }
            .keyboardShortcut("p", modifiers: [.command])
            .padding(.horizontal, 30)
            .padding(.vertical, 8)
            
            Button("Record/Choose Video…") {
                showVideoCapture = true
            }
            .keyboardShortcut("v", modifiers: [.command])
            .padding(.horizontal, 30)
            .padding(.vertical, 8)
            
            Divider()
            Button("Choose Image File…") {
                chooseImageFile()
            }
            .padding(.horizontal, 30)
            
            Button("Choose Video File…") {
                chooseVideoFile()
            }
            .padding(.horizontal, 30)
            
            Divider()
            
            Button("Cancel") {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)
            .padding(.vertical, 6)
        }
        .sheet(isPresented: $showPhotoCapture) {
            PhotoCaptureView { data in
                onPhoto(data, "captured.jpg", "image/jpeg")
                isPresented = false
            } onCancel: {
                showPhotoCapture = false
            }
        }
        .sheet(isPresented: $showVideoCapture) {
            VideoCaptureView { url in
                onVideo(url, url.lastPathComponent, "video/quicktime")
                isPresented = false
            } onCancel: {
                showVideoCapture = false
            }
        }
        .frame(minWidth: 360, minHeight: 220)
        .padding()
    }
    
    private func chooseImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .jpeg,
            .png,
            .gif,
            .bmp,
            .tiff,
            .heic,
            .rawImage,
            .ico,
            .webP
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Choose an Image File"
        panel.message = "Select an image file to upload."
        
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let mime = mimeType(for: url)
                onPhoto(data, url.lastPathComponent, mime)
                isPresented = false
            } catch {
                // Handle error silently or add error handling as needed
            }
        }
    }
    
    private func chooseVideoFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .movie,           // general movie files
            .mpeg4Movie,      // .mp4, .m4v
            .quickTimeMovie   // .mov
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Choose a Video File"
        panel.message = "Select a video file to upload or record a new one."
        
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let mime = mimeType(for: url)
            onVideo(url, url.lastPathComponent, mime)
            isPresented = false
        }
    }
    
    private func mimeType(for url: URL) -> String {
        if let utType = UTType(filenameExtension: url.pathExtension.lowercased()),
           let mime = utType.preferredMIMEType {
            return mime
        }
        // Fallbacks for common extensions
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "tiff", "tif": return "image/tiff"
        case "heic": return "image/heic"
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        case "avi": return "video/x-msvideo"
        case "m4v": return "video/x-m4v"
        default: return "application/octet-stream"
        }
    }
}


// MARK: - Camera Preview Host (macOS)
fileprivate struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
        previewLayer.frame = view.bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = CALayer()
        view.layer?.addSublayer(previewLayer)
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // The preview layer resizes via autoresizing mask
    }
}

// MARK: - Photo Capture
fileprivate struct PhotoCaptureView: View {
    var onCapture: (Data) -> Void
    var onCancel: () -> Void
    
    private let sessionQueue = DispatchQueue(label: "photo.session.queue")
    @State private var session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    @State private var isConfigured = false
    @State private var errorMessage: String?

    var body: some View {
        VStack {
            if let errorMessage {
                VStack(spacing: 8) {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.headline)
                    Text("Please allow camera access in System Settings > Privacy & Security > Camera. Photos only require camera access; microphone is not needed.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    HStack(spacing: 12) {
                        Button("Open Camera Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button("Try Again") {
                            // Attempt to reconfigure the session
                            self.errorMessage = nil
                            self.isConfigured = false
                            configureSession()
                        }
                    }
                    .padding(.top, 4)
                }
                .padding()
            } else {
                CameraPreviewView(session: session)
                    .frame(minWidth: 500, minHeight: 360)
            }
            HStack {
                Button("Cancel") { onCancel() }
                Spacer()
                Button("Capture") {
                    let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                    photoOutput.capturePhoto(with: settings, delegate: PhotoDelegate { data in
                        onCapture(data)
                    })
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isConfigured)
            }
            .padding()
        }
        .onAppear(perform: configureSession)
        .onDisappear { sessionQueue.async { session.stopRunning() } }
        .frame(minWidth: 520, minHeight: 420)
        .padding()
    }
    
    private func configureSession() {
        sessionQueue.async {
            session.beginConfiguration()
            session.sessionPreset = .photo
            
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            if status == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    if granted {
                        configureSession()
                    } else {
                        DispatchQueue.main.async { self.errorMessage = "Camera access denied." }
                    }
                }
                session.commitConfiguration()
                return
            } else if status != .authorized {
                DispatchQueue.main.async { self.errorMessage = "Camera access denied." }
                session.commitConfiguration()
                return
            }
            
            guard let device = AVCaptureDevice.default(for: .video) else {
                DispatchQueue.main.async { self.errorMessage = "No camera available." }
                session.commitConfiguration()
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) { session.addInput(input) }
                if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
                session.commitConfiguration()
                session.startRunning()
                DispatchQueue.main.async { self.isConfigured = true }
            } catch {
                DispatchQueue.main.async { self.errorMessage = "Failed to access camera: \(error.localizedDescription)" }
                session.commitConfiguration()
            }
        }
    }
    
    private nonisolated final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
        let handler: (Data) -> Void
        init(handler: @escaping (Data) -> Void) { self.handler = handler }
        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            if let data = photo.fileDataRepresentation() {
                handler(data)
            }
        }
    }
}

// MARK: - Video Capture
fileprivate struct VideoCaptureView: View {
    var onFinish: (URL) -> Void
    var onCancel: () -> Void
    
    private let sessionQueue = DispatchQueue(label: "video.session.queue")
    @State private var session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    @State private var isConfigured = false
    @State private var isRecording = false
    @State private var errorMessage: String?
    @State private var micErrorMessage: String?

    var body: some View {
        VStack {
            if errorMessage != nil || micErrorMessage != nil {
                VStack(spacing: 8) {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.headline)
                    }
                    if let micErrorMessage {
                        Text(micErrorMessage)
                            .foregroundColor(.red)
                            .font(.headline)
                    }
                    Text("Please allow camera and microphone access in System Settings > Privacy & Security. If you previously denied access, enable them there, then return to this window.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    HStack(spacing: 12) {
                        Button("Open Camera Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button("Open Microphone Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button("Try Again") {
                            self.errorMessage = nil
                            self.micErrorMessage = nil
                            self.isConfigured = false
                            configureSession()
                        }
                    }
                    .padding(.top, 4)
                }
                .padding()
            } else {
                CameraPreviewView(session: session)
                    .frame(minWidth: 500, minHeight: 360)
            }
            HStack {
                Button("Cancel") {
                    if isRecording {
                        movieOutput.stopRecording()
                    }
                    onCancel()
                }
                Spacer()
                if isRecording {
                    Button("Stop Recording") { stopRecording() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Start Recording") { startRecording() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isConfigured)
                }
            }
            .padding()
        }
        .onAppear(perform: configureSession)
        .onDisappear { sessionQueue.async { session.stopRunning() } }
        .frame(minWidth: 520, minHeight: 420)
        .padding()
    }
    
    private func configureSession() {
        sessionQueue.async {
            session.beginConfiguration()
            session.sessionPreset = .high
            
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            if status == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    if granted {
                        configureSession()
                    } else {
                        DispatchQueue.main.async { self.errorMessage = "Camera access denied." }
                    }
                }
                session.commitConfiguration()
                return
            } else if status != .authorized {
                DispatchQueue.main.async { self.errorMessage = "Camera access denied." }
                session.commitConfiguration()
                return
            }
            
            // Microphone authorization
            let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            if micStatus == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    if granted {
                        configureSession()
                    } else {
                        DispatchQueue.main.async { self.micErrorMessage = "Microphone access denied." }
                    }
                }
                session.commitConfiguration()
                return
            } else if micStatus != .authorized {
                DispatchQueue.main.async { self.micErrorMessage = "Microphone access denied." }
                session.commitConfiguration()
                // Continue without audio input; do not return so video can still start if camera is authorized
            }
            
            guard let videoDevice = AVCaptureDevice.default(for: .video) else {
                DispatchQueue.main.async { self.errorMessage = "No camera available." }
                session.commitConfiguration()
                return
            }
            do {
                let videoInput = try AVCaptureDeviceInput(device: videoDevice)
                if session.canAddInput(videoInput) { session.addInput(videoInput) }
                
                // Add audio input for proper movie files
                if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                    if let audioDevice = AVCaptureDevice.default(for: .audio) {
                        do {
                            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                            if session.canAddInput(audioInput) { session.addInput(audioInput) }
                        } catch {
                            DispatchQueue.main.async { self.micErrorMessage = "Failed to access microphone: \(error.localizedDescription)" }
                        }
                    }
                }
                
                if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
                
                session.commitConfiguration()
                session.startRunning()
                DispatchQueue.main.async { self.isConfigured = true }
            } catch {
                DispatchQueue.main.async { self.errorMessage = "Failed to access camera: \(error.localizedDescription)" }
                session.commitConfiguration()
            }
        }
    }
    
    private func startRecording() {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let fileURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        sessionQueue.async {
            movieOutput.startRecording(to: fileURL, recordingDelegate: RecordingDelegate { url in
                DispatchQueue.main.async { onFinish(url) }
            })
        }
        isRecording = true
    }
    
    private func stopRecording() {
        sessionQueue.async { movieOutput.stopRecording() }
        isRecording = false
    }
    
    private nonisolated final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
        let handler: (URL) -> Void
        init(handler: @escaping (URL) -> Void) { self.handler = handler }
        func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
            handler(outputFileURL)
        }
    }
}

