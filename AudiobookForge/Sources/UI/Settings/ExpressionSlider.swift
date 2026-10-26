import SwiftUI

/// "Calmer ↔ livelier" (v4.2): the engine default sits exactly in the
/// middle (marked), each half stretches to its end of the range, the value
/// is shown small, one click resets it, and a sample plays with the setting.
struct ExpressionRow: View {
    let engine: TTSEngineID
    @Binding var value: Double
    let range: ClosedRange<Double>
    let standard: Double
    var note: String? = nil

    @Environment(SettingsStore.self) private var settingsStore
    @StateObject private var preview = VoicePreviewPlayer()
    @State private var voice: VoiceID?

    var body: some View {
        PillRow(title: engine.shortName, subtitle: note) {
            HStack(spacing: 10) {
                ExpressionSlider(value: $value, range: range, standard: standard)
                Button {
                    value = standard
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(ExpressionDefaults.isStandard(value, standard) ? 0.3 : 1)
                .disabled(ExpressionDefaults.isStandard(value, standard))
                .help("Auf Standard zurücksetzen")
                Button {
                    guard let voice else { return }
                    let settings = settingsStore.settings
                    preview.toggle(text: Self.sampleText(for: voice), engineID: voice.engine, voice: voice.voice,
                                   speed: settings.defaultSpeed(for: voice.engine), settings: settings)
                } label: {
                    Image(systemName: preview.isPlaying || preview.isGenerating ? "stop.fill" : "play.fill")
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .disabled(voice == nil)
                .help(voice == nil ? L("Zum Probehören zuerst eine Stimme dieser Engine installieren") : L("Probe mit dieser Einstellung"))
            }
        }
        .task { voice = await installedVoice() }
        .onReceive(NotificationCenter.default.publisher(for: .engineInventoryChanged)) { _ in Task { voice = await installedVoice() } }
    }

    /// A voice of this engine that is installed: the user's default for a
    /// language if it uses this engine, else the first installed one.
    private func installedVoice() async -> VoiceID? {
        let settings = settingsStore.settings
        let engine = engine
        return await Task.detached(priority: .utility) { () -> VoiceID? in
            let defaults = VoiceCatalog.galleryLanguages.map { settings.defaultVoiceID(forLanguage: $0) }.filter { $0.engine == engine }
            let candidates = defaults + VoiceCatalog.allProfiles.filter { $0.id.engine == engine }.map(\.id)
            return candidates.first { EngineInventory.missingComponents(for: $0, settings: settings).isEmpty }
        }.value
    }

    /// Dialogue and a question — where expression is audible. Deliberately not
    /// the catalog sample text, whose bundled recording would play instead.
    static func sampleText(for voice: VoiceID) -> String {
        switch VoiceCatalog.profile(for: voice)?.baseLanguage ?? "de" {
        case "en": return "\"Did you really think I would not notice?\" she asked, and laughed. Then she grew quiet and looked out at the sea."
        case "fr": return "« Tu pensais vraiment que je ne remarquerais rien ? » demanda-t-elle en riant. Puis elle se tut et regarda la mer."
        case "es": return "«¿De verdad creías que no me daría cuenta?», preguntó ella, riendo. Luego guardó silencio y miró el mar."
        case "it": return "«Pensavi davvero che non me ne sarei accorta?» chiese lei ridendo. Poi tacque e guardò il mare."
        default: return "„Hast du wirklich geglaubt, ich merke das nicht?“, fragte sie und lachte. Dann wurde sie still und sah hinaus aufs Meer."
        }
    }
}

/// Slider whose middle is the default (piecewise linear on both halves).
struct ExpressionSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let standard: Double
    @Environment(\.flowAccent) private var accent

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Slider(value: Binding(
                    get: { ExpressionDefaults.position(of: value, range: range, standard: standard) },
                    set: { value = (ExpressionDefaults.value(atPosition: $0, range: range, standard: standard) * 1000).rounded() / 1000 }
                ), in: 0...1)
                Capsule()
                    .fill(.secondary)
                    .frame(width: 2, height: 7)
                    .offset(y: -11)
                    .allowsHitTesting(false)
            }
            HStack {
                Text("ruhiger")
                Spacer()
                Text(verbatim: ExpressionDefaults.isStandard(value, standard) ? L("Standard") : String(format: "%.2f", value))
                    .monospacedDigit()
                    .foregroundStyle(ExpressionDefaults.isStandard(value, standard) ? .secondary : .primary)
                Spacer()
                Text("lebendiger")
            }
            .flowFont(.caption2)
            .foregroundStyle(.secondary)
        }
        .tint(accent.color)
        .frame(width: 240)
    }
}
