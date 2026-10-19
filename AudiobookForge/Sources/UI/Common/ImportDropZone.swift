import SwiftUI
import UniformTypeIdentifiers

struct ImportDropZone: View {
    var onImport: ([URL]) -> Void
    @Environment(SettingsStore.self) private var settingsStore
    @State private var isTargeted = false
    @State private var showFileImporter = false

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.pink.opacity(0.85), Color.orange.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 76, height: 76)
                    .shadow(color: Color.orange.opacity(0.3), radius: 12, x: 0, y: 6)

                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.top, 8)

            VStack(spacing: 6) {
                Text("PDF oder EPUB hierher ziehen")
                    .font(.title2.weight(.semibold))
                Text("Mehrfachauswahl möglich, auch gemischt PDF + EPUB")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            @Bindable var store = settingsStore
            VStack(spacing: 8) {
                Picker("Dokumenttyp", selection: $store.settings.defaultDocumentType) {
                    ForEach(DocumentType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 400)

                Text(settingsStore.settings.defaultDocumentType == .paper
                     ? "Paper: zweispaltige Artikel – Abschnitte wie „2 Related Work“ werden erkannt, Literaturverzeichnis und Ergebnistabellen entfallen."
                     : "Bei Unsicherheit „Allgemein“ lassen; „Paper“ nur für wissenschaftliche Artikel wählen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Button {
                showFileImporter = true
            } label: {
                Label("Datei(en) auswählen …", systemImage: "plus")
            }
            .buttonStyle(FlowButtonStyle(variant: .prominent))
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: 540)
        .padding(36)
        .flowPanel(cornerRadius: Theme.Radius.panel)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(isTargeted ? Theme.tint(for: settingsStore.settings.accent) : Color.clear, lineWidth: 2)
                .animation(.easeInOut(duration: 0.2), value: isTargeted)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
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
