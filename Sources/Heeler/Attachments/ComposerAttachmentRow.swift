import SwiftUI

/// Staged paths waiting under the draft, as tiles: a picture where Chat can
/// read one, else its kind. Send puts the paths after the text.
struct ComposerAttachmentRow: View {
    let paths: [String]
    let thumbnails: ChatImageThumbnails?
    let remove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(paths, id: \.self) { path in
                    ComposerAttachmentTile(path: path, thumbnails: thumbnails) { remove(path) }
                }
            }
            // Room for each tile's remove badge, which sits over its corner.
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
    }
}

private struct ComposerAttachmentTile: View {
    static let size: CGFloat = 56

    let path: String
    let thumbnails: ChatImageThumbnails?
    let remove: () -> Void

    private var name: String { RemoteHostPath.lastComponent(of: path) }
    private var isImage: Bool { ChatImageLink.path(written: path) != nil }

    var body: some View {
        content
            .frame(width: Self.size, height: Self.size)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(white: 0.25))
                }
                .buttonStyle(.plain)
                .offset(x: 7, y: -7)
                .accessibilityLabel(Text("Remove"))
                .accessibilityValue(Text(verbatim: name))
            }
            .onAppear { if isImage { thumbnails?.appear(path) } }
            .onDisappear { if isImage { thumbnails?.disappear(path) } }
    }

    @ViewBuilder
    private var content: some View {
        if isImage, let image = thumbnails?.image(of: path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .accessibilityLabel(Text(verbatim: name))
        } else {
            ZStack {
                Color(uiColor: .tertiarySystemFill)
                Image(systemName: isImage ? "photo" : "doc")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: name))
        }
    }
}
