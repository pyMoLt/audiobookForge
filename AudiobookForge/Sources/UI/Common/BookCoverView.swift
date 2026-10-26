import SwiftUI
import AppKit

/// A book's cover at any size: displays the imported cover image at its full,
/// original high resolution, or a dynamically generated typeset cover when
/// no image is present.
struct BookCoverView: View {
    let book: BookProject
    var width: CGFloat
    /// Width / height. Book covers are portrait; 0.72 ≈ A-format.
    var aspect: CGFloat = 0.72
    var showsShadow: Bool = true

    @Environment(LibraryStore.self) private var libraryStore
    private var height: CGFloat { width / aspect }

    var body: some View {
        ZStack {
            if let image = CoverImageCache.image(for: book, root: libraryStore.rootURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                GeneratedCover(title: book.title, author: book.author, seed: book.id, width: width, height: height)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: max(3, width * 0.035), style: .continuous))
        .shadow(color: Color.black.opacity(showsShadow ? 0.35 : 0), radius: max(2, width * 0.04), x: 0, y: max(1, width * 0.02))
        .accessibilityHidden(true)
    }
}

private struct GeneratedCover: View {
    let title: String
    let author: String
    let seed: UUID
    let width: CGFloat
    let height: CGFloat

    private var palette: (Color, Color) {
        let palettes: [(Color, Color)] = [
            (Color(red: 0.35, green: 0.30, blue: 0.75), Color(red: 0.62, green: 0.45, blue: 0.95)),
            (Color(red: 0.08, green: 0.40, blue: 0.55), Color(red: 0.20, green: 0.70, blue: 0.75)),
            (Color(red: 0.70, green: 0.25, blue: 0.25), Color(red: 0.95, green: 0.55, blue: 0.40)),
            (Color(red: 0.15, green: 0.42, blue: 0.30), Color(red: 0.45, green: 0.72, blue: 0.48)),
            (Color(red: 0.55, green: 0.30, blue: 0.10), Color(red: 0.92, green: 0.68, blue: 0.32)),
            (Color(red: 0.20, green: 0.24, blue: 0.40), Color(red: 0.45, green: 0.52, blue: 0.72)),
            (Color(red: 0.62, green: 0.20, blue: 0.45), Color(red: 0.92, green: 0.48, blue: 0.62)),
        ]
        let index = Int(seed.uuid.0 ^ seed.uuid.7 ^ seed.uuid.15) % palettes.count
        return palettes[index]
    }

    var body: some View {
        let (deep, light) = palette
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [light, deep], startPoint: .topLeading, endPoint: .bottomTrailing)
            // Soft light orb for depth.
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: width * 0.6))
                .frame(width: width * 1.2, height: width * 1.2)
                .offset(x: width * 0.25, y: -width * 0.35)
            if width >= 60 {
                VStack(alignment: .leading, spacing: width * 0.04) {
                    Rectangle().fill(Color.white.opacity(0.7)).frame(width: width * 0.18, height: 2)
                    Text(title)
                        .appFont(size: width * 0.105, weight: .semibold, design: .serif)
                        .foregroundStyle(.white)
                        .lineLimit(5)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    if !author.isEmpty {
                        Text(author)
                            .appFont(size: width * 0.065, weight: .medium)
                            .foregroundStyle(Color.white.opacity(0.85))
                            .lineLimit(2)
                    }
                }
                .padding(width * 0.11)
                .frame(width: width, height: height, alignment: .topLeading)
            } else {
                Text(String(title.prefix(1)).uppercased())
                    .appFont(size: width * 0.5, weight: .semibold, design: .serif)
                    .foregroundStyle(.white)
                    .frame(width: width, height: height)
            }
        }
        .frame(width: width, height: height)
    }
}

/// Decoding cover JPEG/PNG data on every body evaluation was measurable
/// in the sidebar; cache the NSImage per book (data identity by count).
enum CoverImageCache {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 100
        return c
    }()

    /// In-memory cover data, or — for books not hydrated yet — the stored
    /// cover file (thumbnail for small sizes is enough for lists/shelf).
    static func image(for book: BookProject, root: URL) -> NSImage? {
        if let data = book.coverImageData { return image(for: book.id, data: data) }
        let key = "file-\(book.id.uuidString)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        for url in [LibraryLayout.coverURL(root, bookID: book.id), LibraryLayout.coverThumbURL(root, bookID: book.id)] {
            if let image = NSImage(contentsOf: url) {
                cache.setObject(image, forKey: key)
                return image
            }
        }
        return nil
    }

    nonisolated(unsafe) private static let pixelCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 150
        return c
    }()

    /// The cover as pixel art at one of `PixelArt.widthSteps`. Books
    /// without a cover image get their generated cover pixelated the same
    /// way, so the shelf has one look.
    @MainActor
    static func pixelImage(for book: BookProject, root: URL, artWidth: Int) -> NSImage? {
        let source = image(for: book, root: root)
        let identity = source.map { "\(Int($0.size.width))x\(Int($0.size.height))-\(book.coverImageData?.count ?? 0)" }
            ?? "gen-\(book.title.hashValue)-\(book.author.hashValue)"
        let key = "pix-\(book.id.uuidString)-\(identity)-\(artWidth)" as NSString
        if let cached = pixelCache.object(forKey: key) { return cached }
        let cgImage: CGImage?
        if let source {
            cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
        } else {
            let renderer = ImageRenderer(content: GeneratedCover(title: book.title, author: book.author, seed: book.id, width: 180, height: 250))
            renderer.scale = 1
            cgImage = renderer.cgImage
        }
        guard let cgImage, let art = PixelArt.pixelate(cgImage, artWidth: artWidth) else { return nil }
        let result = NSImage(cgImage: art, size: NSSize(width: art.width, height: art.height))
        pixelCache.setObject(result, forKey: key)
        return result
    }

    static func image(for bookID: UUID, data: Data) -> NSImage? {
        let key = "\(bookID.uuidString)-\(data.count)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
