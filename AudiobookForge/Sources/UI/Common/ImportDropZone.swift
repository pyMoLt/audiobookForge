import SwiftUI
import UniformTypeIdentifiers

struct ImportDropZone: View {
    var onImport: ([URL]) -> Void
    @Environment(SettingsStore.self) private var settingsStore
    @State private var isTargeted = false
    @State private var showFileImporter = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("PDF oder EPUB hierher ziehen")
                .font(.title3.weight(.medium))
            Text("Mehrfachauswahl möglich, auch gemischt PDF + EPUB")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            @Bindable var store = settingsStore
            Picker("Dokumenttyp", selection: $store.settings.defaultDocumentType) {
                ForEach(DocumentType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            Text(settingsStore.settings.defaultDocumentType == .paper
                 ? "Paper: zweispaltige Artikel – Abschnitte wie „2 Related Work“ werden erkannt, Literaturverzeichnis und Ergebnistabellen entfallen."
                 : "Bei Unsicherheit „Allgemein“ lassen; „Paper“ nur für wissenschaftliche Artikel wählen.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Datei(en) auswählen…") {
                showFileImporter = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.3))
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(24)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf, UTType(filenameExtension: "epub")].compactMap { $0 }, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                onImport(urls)
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        let urls = LockedBox<[URL]>([])
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    urls.withLock { $0.append(url) }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let supported = urls.withLock { $0.filter { ["pdf", "epub"].contains($0.pathExtension.lowercased()) } }
            if !supported.isEmpty {
                onImport(supported)
            }
        }
    }
}
