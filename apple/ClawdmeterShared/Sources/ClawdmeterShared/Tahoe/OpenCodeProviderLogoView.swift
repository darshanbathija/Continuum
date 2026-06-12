#if canImport(SwiftUI)
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public enum OpenCodeProviderLogo {
    public static func logoURL(for providerId: String) -> URL? {
        let trimmed = providerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? trimmed
        return URL(string: "https://models.dev/logos/\(encoded).svg")
    }
}

public actor OpenCodeProviderLogoLoader {
    public static let shared = OpenCodeProviderLogoLoader()

    private var cache: [String: Data] = [:]
    private var inflight: [String: Task<Data?, Never>] = [:]

    private static let diskCacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("clawdmeter/opencode-logos", isDirectory: true)
    }()

    public func svgData(for providerId: String) async -> Data? {
        let key = providerId.lowercased()
        if let cached = cache[key] {
            return cached
        }
        if let disk = Self.readDiskCache(for: key) {
            cache[key] = disk
            return disk
        }
        if let task = inflight[key] {
            return await task.value
        }
        let task = Task<Data?, Never> {
            await Self.fetchSVG(providerId: providerId)
        }
        inflight[key] = task
        let data = await task.value
        inflight[key] = nil
        if let data {
            cache[key] = data
            Self.writeDiskCache(data, for: key)
        }
        return data
    }

    public func preload(providerIds: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for providerId in providerIds {
                group.addTask {
                    _ = await self.svgData(for: providerId)
                }
            }
        }
    }

    private static func diskCacheURL(for key: String) -> URL {
        diskCacheDirectory.appendingPathComponent("\(key).svg")
    }

    private static func readDiskCache(for key: String) -> Data? {
        let url = diskCacheURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func writeDiskCache(_ data: Data, for key: String) {
        let directory = diskCacheDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: diskCacheURL(for: key), options: .atomic)
    }

    private static func fetchSVG(providerId: String) async -> Data? {
        guard let url = OpenCodeProviderLogo.logoURL(for: providerId) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }
}

/// Brand mark for an OpenCode upstream provider from models.dev.
public struct OpenCodeProviderLogoView: View {
    public var providerId: String
    public var fallbackLabel: String
    public var size: CGFloat

    @State private var logoImage: Image?

    public init(providerId: String, fallbackLabel: String? = nil, size: CGFloat = 28) {
        self.providerId = providerId
        self.fallbackLabel = fallbackLabel ?? OpenCodePartnerSupport.displayName(for: providerId)
        self.size = size
    }

    public var body: some View {
        let imageRadius = size * 0.24
        ZStack {
            RoundedRectangle(cornerRadius: imageRadius, style: .continuous)
                .fill(ContinuumTokens.surface2)
            if let logoImage {
                logoImage
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(ContinuumTokens.fg)
                    .frame(width: size * 0.74, height: size * 0.74)
            } else {
                fallbackMonogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: imageRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: imageRadius, style: .continuous)
                .strokeBorder(ContinuumTokens.hairline, lineWidth: 0.5)
        }
        .task(id: providerId) {
            logoImage = await Self.loadImage(for: providerId)
        }
    }

    private var fallbackMonogram: some View {
        let letter = fallbackLabel.first.map(String.init) ?? "?"
        return Text(letter.uppercased())
            .font(ContinuumFont.display(size * 0.46, weight: .bold))
            .tracking(-0.4)
            .foregroundStyle(ContinuumTokens.fg2)
    }

    @MainActor
    private static func loadImage(for providerId: String) async -> Image? {
        guard let data = await OpenCodeProviderLogoLoader.shared.svgData(for: providerId) else {
            return nil
        }
        #if canImport(AppKit)
        guard let nsImage = NSImage(data: data), nsImage.isValid else { return nil }
        return Image(nsImage: nsImage)
        #elseif canImport(UIKit)
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #else
        return nil
        #endif
    }
}
#endif
