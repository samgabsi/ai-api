import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

struct WebcamCaptureSheet: View {
    @Binding var isPresented: Bool
    var onPhoto: (Data, String, String) -> Void
    var onVideo: (URL, String, String) -> Void
    
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
                // TODO: Implement live photo capture using AVCapturePhotoOutput if camera permission is available.
                // For now, fallback to image file picker.
                chooseImageFile()
            }
            .keyboardShortcut("p", modifiers: [.command])
            .padding(.horizontal, 30)
            .padding(.vertical, 8)
            
            Button("Record/Choose Video…") {
                // TODO: Implement live video recording using AVCaptureMovieFileOutput if needed.
                // For now, use video file picker.
                chooseVideoFile()
            }
            .keyboardShortcut("v", modifiers: [.command])
            .padding(.horizontal, 30)
            .padding(.vertical, 8)
            
            Divider()
            
            Button("Cancel") {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)
            .padding(.vertical, 6)
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
            .movie,
            .mpeg4Movie,
            .avi,
            .quickTimeMovie,
            .mp3,
            .wav,
            .aiff,
            .mp4
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
