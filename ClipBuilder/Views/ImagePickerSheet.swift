import AppKit
import SwiftUI

/// Thumbnail-grid modal over the Images asset library: click to select any
/// number of images, then add them all at once. Replaces the old
/// filename-only dropdown pickers.
struct ImagePickerSheet: View {
    /// Called with every selected image's file URL, in library order.
    let onAdd: ([URL]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var files: [(name: String, url: URL)] = []
    @State private var selectedPaths: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Images")
                        .font(.headline)
                    Text("Click to select one or more images from your library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Images Folder") {
                    try? FileManager.default.createDirectory(at: AssetKind.images.rootURL,
                                                             withIntermediateDirectories: true)
                    NSWorkspace.shared.open(AssetKind.images.rootURL)
                }
                .controlSize(.small)
                .help("Drop new files into the folder, then reopen this picker")
            }
            .padding()

            if files.isEmpty {
                ContentUnavailableView(
                    "No images yet",
                    systemImage: "photo",
                    description: Text("Add images in the Images section (or the folder above) first — then pick them here."))
                    .frame(height: 240)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12, alignment: .top)],
                              spacing: 12) {
                        ForEach(files, id: \.url.path) { file in
                            cell(for: file)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                .frame(minHeight: 260, idealHeight: 340, maxHeight: 420)
            }

            HStack {
                if !selectedPaths.isEmpty {
                    Text("\(selectedPaths.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(selectedPaths.count > 1 ? "Add \(selectedPaths.count) Images" : "Add Image") {
                    let urls = files.map(\.url).filter { selectedPaths.contains($0.path) }
                    dismiss()
                    onAdd(urls)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedPaths.isEmpty)
            }
            .padding()
        }
        .frame(width: 560)
        .onAppear { files = AssetStore.allFiles(of: .images) }
    }

    @ViewBuilder
    private func cell(for file: (name: String, url: URL)) -> some View {
        let isSelected = selectedPaths.contains(file.url.path)
        VStack(spacing: 4) {
            ImageThumbnail(url: file.url)
                .frame(height: 110)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(5)
                    }
                }
            Text(file.name)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected {
                selectedPaths.remove(file.url.path)
            } else {
                selectedPaths.insert(file.url.path)
            }
        }
    }
}
