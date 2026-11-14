import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var storage: StorageManager
    @Environment(\.dismiss) private var dismiss

    @AppStorage("showGrid") private var showGrid = false
    @AppStorage("mirrorFront") private var mirrorFront = true
    @AppStorage("photoFormat") private var photoFormat = "heic"

    @State private var showPicker = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Save To", selection: $storage.destination) {
                        Text("Photo Library").tag(SaveDestination.photoLibrary)
                        Text("Custom Folder").tag(SaveDestination.customFolder)
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("If the custom folder isn't available, photos and videos are saved to the Photo Library instead.")
                }

                Section {
                    HStack {
                        Text("Folder")
                        Spacer()
                        Text(storage.folderName ?? "None selected")
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    HStack {
                        Text("Status")
                        Spacer()
                        statusLabel
                    }
                    Button("Choose Folder…") { showPicker = true }
                    if storage.hasFolder {
                        Button("Remove Folder", role: .destructive) { storage.clearFolder() }
                    }
                } header: {
                    Text("Custom Folder")
                } footer: {
                    Text("To save to a USB drive, connect it with a Lightning to USB adapter, tap Choose Folder, then pick or create a folder on the drive. Drives must be formatted APFS, exFAT, FAT32 or HFS+ (NTFS is read-only on iOS). Some drives need a powered adapter such as the Lightning to USB 3 Camera Adapter with a charger attached.")
                }

                Section("Camera") {
                    Toggle("Grid", isOn: $showGrid)
                    Toggle("Mirror Front Camera", isOn: $mirrorFront)
                    Picker("Photo Format", selection: $photoFormat) {
                        Text("High Efficiency (HEIC)").tag("heic")
                        Text("Most Compatible (JPEG)").tag("jpeg")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { storage.refreshStatus() }
            .sheet(isPresented: $showPicker) {
                FolderPicker { url in
                    if case .failure(let error) = storage.setFolder(url) {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            .alert("Can't Use Folder", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch storage.folderStatus {
        case .none:
            Text("—").foregroundColor(.secondary)
        case .available:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .unavailable:
            Label("Not available – using Photo Library", systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.footnote)
        }
    }
}
