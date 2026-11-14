import SwiftUI

struct CameraView: View {
    @StateObject private var model = CameraModel()
    @EnvironmentObject private var storage: StorageManager
    @AppStorage("showGrid") private var showGrid = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch model.authState {
            case .authorized:
                cameraBody
            case .denied:
                PermissionView()
            case .unknown:
                ProgressView().tint(.white)
            }

            if let toast = model.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.footnote.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .padding(.bottom, 190)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .onAppear { model.start() }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(storage)
        }
    }

    // MARK: - Main layout

    private var cameraBody: some View {
        VStack(spacing: 0) {
            topBar

            ZStack {
                CameraPreview(model: model)
                    .aspectRatio(model.mode.aspectRatio, contentMode: .fit)
                    .overlay {
                        if showGrid { GridOverlay().allowsHitTesting(false) }
                    }
                    .overlay {
                        ZStack {
                            if let p = model.focusPoint {
                                FocusIndicator(bias: model.exposureBias)
                                    .position(p)
                                    .transition(.opacity)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    .overlay(alignment: .top) {
                        if model.isRecording {
                            recordingPill.padding(.top, 10).allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if !model.lenses.isEmpty {
                            lensPicker.padding(.bottom, 10)
                        }
                    }
                    .clipped()

                if let c = model.countdown {
                    Text("\(c)")
                        .font(.system(size: 96, weight: .thin))
                        .foregroundColor(.yellow)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.25), value: model.mode)
            .animation(.easeOut(duration: 0.2), value: model.focusPoint == nil)

            bottomBar
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 18) {
            if model.flashSupported {
                Button { model.cycleFlash() } label: {
                    Image(systemName: model.flash.icon)
                        .foregroundColor(model.flash == .on ? .yellow : .white)
                        .frame(width: 32, height: 32)
                }
            } else {
                Color.clear.frame(width: 32, height: 32)
            }

            Spacer()

            storageChip

            Spacer()

            if model.liveSupported {
                Button { model.toggleLive() } label: {
                    Image(systemName: model.livePhotoOn ? "livephoto" : "livephoto.slash")
                        .foregroundColor(model.livePhotoOn ? .yellow : .white)
                        .frame(width: 32, height: 32)
                }
            }

            if !model.mode.isVideo {
                Button { model.cycleTimer() } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "timer")
                        if model.timerSeconds > 0 {
                            Text("\(model.timerSeconds)s").font(.caption.weight(.semibold))
                        }
                    }
                    .foregroundColor(model.timerSeconds > 0 ? .yellow : .white)
                    .frame(minWidth: 32, minHeight: 32)
                }
            }

            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
            }
        }
        .font(.system(size: 19))
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var storageChip: some View {
        let info = chipInfo
        return Button { showSettings = true } label: {
            HStack(spacing: 4) {
                Image(systemName: info.icon)
                Text(info.text).lineLimit(1)
            }
            .font(.caption2.weight(.semibold))
            .foregroundColor(info.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.12)))
        }
    }

    private var chipInfo: (icon: String, text: String, color: Color) {
        switch (storage.destination, storage.folderStatus) {
        case (.customFolder, .available):
            return ("externaldrive.fill", storage.folderName ?? "Folder", .white)
        case (.customFolder, _):
            return ("exclamationmark.triangle.fill", "Photos (folder missing)", .yellow)
        default:
            return ("photo.on.rectangle", "Photos", .white)
        }
    }

    // MARK: - Overlays

    private var recordingPill: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Text(timeString(model.recordingSeconds))
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundColor(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.red.opacity(0.55)))
    }

    private var lensPicker: some View {
        HStack(spacing: 8) {
            ForEach(Array(model.lenses.enumerated()), id: \.element.id) { index, lens in
                let selected = index == selectedLensIndex
                Button {
                    model.setZoom(lens.zoom, ramp: true)
                } label: {
                    Text(lensLabel(lens, selected: selected))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(selected ? .yellow : .white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                        .scaleEffect(selected ? 1.08 : 0.92)
                }
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.black.opacity(0.25)))
    }

    private var selectedLensIndex: Int {
        var idx = 0
        for (i, l) in model.lenses.enumerated() where l.zoom <= model.zoom + 0.05 { idx = i }
        return idx
    }

    private func lensLabel(_ lens: Lens, selected: Bool) -> String {
        if selected && abs(model.zoom - lens.zoom) > 0.05 {
            return String(format: "%.1f×", model.zoom)
        }
        return lens.label + (selected ? "×" : "")
    }

    // MARK: - Bottom bar

    private var availableModes: [CameraMode] {
        CameraMode.allCases.filter { $0 != .portrait || model.portraitSupported }
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            modeSelector

            HStack {
                thumbnailButton
                Spacer()
                shutterButton
                Spacer()
                flipButton
            }
            .padding(.horizontal, 32)
        }
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(Color.black)
    }

    private var modeSelector: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 22) {
                        ForEach(availableModes) { m in
                            Button { model.setMode(m) } label: {
                                Text(m.rawValue)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(m == model.mode ? .yellow : .white)
                            }
                            .id(m)
                        }
                    }
                    .padding(.horizontal, max(0, geo.size.width / 2 - 30))
                }
                .onChange(of: model.mode) { new in
                    withAnimation { proxy.scrollTo(new, anchor: .center) }
                }
                .onAppear { proxy.scrollTo(model.mode, anchor: .center) }
            }
        }
        .frame(height: 24)
        .disabled(model.isRecording)
    }

    private var shutterButton: some View {
        Button { model.shutterTapped() } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 74, height: 74)
                if model.mode.isVideo {
                    RoundedRectangle(cornerRadius: model.isRecording ? 8 : 30)
                        .fill(Color.red)
                        .frame(width: model.isRecording ? 30 : 60, height: model.isRecording ? 30 : 60)
                        .animation(.easeInOut(duration: 0.2), value: model.isRecording)
                } else {
                    Circle()
                        .fill(model.countdown != nil ? Color.gray : Color.white)
                        .frame(width: 60, height: 60)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var thumbnailButton: some View {
        Button { openGallery() } label: {
            Group {
                if let t = model.thumbnail {
                    Image(uiImage: t).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.15)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.4), lineWidth: 1))
        }
    }

    private var flipButton: some View {
        Button { model.flipCamera() } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.system(size: 22))
                .foregroundColor(.white)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.white.opacity(0.15)))
        }
        .disabled(model.isRecording)
    }

    // MARK: - Helpers

    private func openGallery() {
        if model.lastSavedToFolder, let folder = storage.folderURL(),
           var comps = URLComponents(url: folder, resolvingAgainstBaseURL: false) {
            comps.scheme = "shareddocuments"
            if let url = comps.url {
                UIApplication.shared.open(url)
                return
            }
        }
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url)
        }
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Small views

struct GridOverlay: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: g.size.height))
                    let y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
        }
    }
}

struct FocusIndicator: View {
    let bias: Float

    var body: some View {
        ZStack {
            Rectangle()
                .stroke(Color.yellow, lineWidth: 1.5)
                .frame(width: 72, height: 72)
            Image(systemName: "sun.max.fill")
                .font(.system(size: 16))
                .foregroundColor(.yellow)
                .offset(x: 54, y: CGFloat(-bias) * 28)
        }
    }
}

struct PermissionView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill").font(.system(size: 44)).foregroundColor(.white)
            Text("Camera access is off")
                .font(.title3.weight(.semibold))
                .foregroundColor(.white)
            Text("Allow camera access in Settings to take photos and videos.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 40)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
