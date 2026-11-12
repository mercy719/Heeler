import SwiftUI

/// An image row's picture, under its title. A frame waiting, failing or
/// offline holds the full height; a picture takes its own size within it,
/// so a wide screenshot leaves no empty band below. A tap opens the
/// zoomable sheet.
struct ChatImageThumbnail: View {
    static let height: CGFloat = 180
    /// On a wide screen it stays a thumbnail.
    static let maximumWidth: CGFloat = 480
    /// The frame that stands in until a picture shows.
    static let placeholderWidth: CGFloat = 240
    private static let cornerRadius: CGFloat = 8

    let path: String
    let thumbnails: ChatImageThumbnails?
    /// Opens the sheet, with the picture shown so far.
    let open: (UIImage?) -> Void
    /// The user's own images sit on the right, above their bubble.
    var isTrailing = false

    var body: some View {
        sized
            .frame(maxWidth: .infinity, alignment: isTrailing ? .trailing : .leading)
            .onAppear { thumbnails?.appear(path) }
            .onDisappear { thumbnails?.disappear(path) }
            .onChange(of: path) { old, new in
                thumbnails?.disappear(old)
                thumbnails?.appear(new)
            }
    }

    @ViewBuilder
    private var sized: some View {
        if case .loaded = thumbnails?.phase(of: path) {
            FittedBox(limit: CGSize(width: Self.maximumWidth, height: Self.height)) { content }
        } else {
            content
                .frame(maxWidth: Self.maximumWidth, alignment: isTrailing ? .trailing : .leading)
                .frame(height: Self.height, alignment: isTrailing ? .topTrailing : .topLeading)
        }
    }

    private var name: String {
        RemoteHostPath.lastComponent(of: path)
    }

    @ViewBuilder
    private var content: some View {
        switch thumbnails?.phase(of: path) ?? .offline {
        case .loaded(let image):
            Button {
                open(image)
            } label: {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: Self.cornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.cornerRadius)
                            .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Image, \(name)")
            .accessibilityHint("Opens the image")
            .accessibilityIdentifier("chat.image-thumbnail")
        case .loading:
            placeholder {
                ProgressView()
            }
            .accessibilityElement()
            .accessibilityLabel("Loading image, \(name)")
            .accessibilityIdentifier("chat.image-thumbnail.loading")
        case .large(let bytes):
            let size = Int64(bytes).formatted(.byteCount(style: .file))
            Button {
                thumbnails?.load(path)
            } label: {
                placeholder {
                    note(size, action: String(localized: "Tap to Load"), symbol: "arrow.down.circle")
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Load image, \(name), \(size)")
            .accessibilityIdentifier("chat.image-thumbnail.large")
        case .offline:
            placeholder {
                note(String(localized: "Connect to the Host to show this image"), symbol: "wifi.slash")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.image-thumbnail.offline")
        case .failed(let message):
            Button {
                thumbnails?.load(path)
            } label: {
                placeholder {
                    note(message, action: String(localized: "Try Again"), symbol: "exclamationmark.triangle")
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(message)
            .accessibilityHint("Tries again")
            .accessibilityIdentifier("chat.image-thumbnail.failed")
        }
    }

    private func placeholder(@ViewBuilder _ content: () -> some View) -> some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius)
            .fill(Color(uiColor: .tertiarySystemFill))
            .frame(maxWidth: Self.placeholderWidth, maxHeight: .infinity)
            .overlay {
                content()
                    .padding(12)
            }
            .contentShape(.rect(cornerRadius: Self.cornerRadius))
    }

    /// What a frame without a picture says, and what a tap on it does when
    /// it is a button.
    private func note(_ text: String, action: String? = nil, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(verbatim: text)
                .foregroundStyle(.secondary)
            if let action {
                Text(verbatim: action)
                    .foregroundStyle(.tint)
            }
        }
        .font(.caption)
        .multilineTextAlignment(.center)
        .lineLimit(3)
        .minimumScaleFactor(0.7)
    }
}

/// Offers its content the thumbnail's box and takes the size the content
/// fits into it, rather than the whole box.
private struct FittedBox: Layout {
    let limit: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let box = ProposedViewSize(
            width: min(proposal.width ?? limit.width, limit.width), height: limit.height)
        return subviews.first?.sizeThatFits(box) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
