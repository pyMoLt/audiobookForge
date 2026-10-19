import SwiftUI
import AVFoundation

/// Creates a cloned voice (user request 2026-10-18): either record into the
/// app (microphone) or use an imported audio file, plus name + transcript.
/// The reference should be 10+ seconds of clean speech of ONE voice —
/// engines clip to ~10 s and use the transcript for the speaker match.
struct VoiceCloneEditorView: View {
    enum Mode: Equatable {
        case record
        case importedFile(URL)
    }

    let mode: Mode
    /// Called after the clone was saved (gallery refreshes its list).
    var onSaved: (VoiceClone) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var refText = ""
    @State private var languageCode = "de"
    @State private var isRecording = false
    @State private var isPlaying = false
    @State private var recordingURL: URL?
    @State private var recorder: AVAudioRecorder?
    @State private var player: AVAudioPlayer?
    @State private var errorMessage: String?
    @State private var secondsRecorded: TimeInterval = 0
    @State private var meterTimer: Timer?

    /// Recording booth: one big record button, level-free and calm.
    @ViewBuilder
    private var referenceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch mode {
            case .record:
                HStack(spacing: 18) {
                    Button {
                        if recordingURL != nil && !isRecording { startRecording() } else { isRecording ? stopRecording() : startRecording() }
                    } label: {
                        ZStack {
                            Circle().fill(Color.red.opacity(isRecording ? 0.9 : 0.85))
                            if isRecording {
                                RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 18, height: 18)
                            } else {
                                Circle().fill(.white.opacity(0.9)).frame(width: 18, height: 18)
                            }
                        }
                        .frame(width: 58, height: 58)
                        .shadow(color: .red.opacity(0.35), radius: 10, y: 4)
                    }
                    .buttonStyle(PressableStyle())
                    .help(isRecording ? L("Aufnahme stoppen") : L("Aufnahme starten"))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isRecording ? "Aufnahme läuft …" : (recordingURL == nil ? "Bereit zur Aufnahme" : "Aufnahme vorhanden"))
                            .flowFont(.headline)
                        Text(String(format: "%.0f s", secondsRecorded))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if recordingURL != nil && !isRecording {
                        Button {
                            togglePlayback()
                        } label: {
                            Label(isPlaying ? "Wiedergabe stoppen" : "Aufnahme anhören", systemImage: isPlaying ? "stop.fill" : "play.fill")
                        }
                        .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                    }
                }
                Text("10–20 Sekunden gleichmäßiges Sprechen EINER Stimme in ruhiger Umgebung. Längere Aufnahmen werden auf 10 Sekunden gekürzt.")
                    .flowFont(.callout)
                    .foregroundStyle(.secondary)
            case .importedFile(let url):
                Label(url.lastPathComponent, systemImage: "waveform")
                    .flowFont(.body, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Die Datei wird kopiert — das Original bleibt unverändert an Ort und Stelle.")
                    .flowFont(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .flowSurface(cornerRadius: Theme.Radius.card)
    }

    private let suggestedText = "Willkommen bei meinem Hörbuch. Diese Aufnahme dient als Vorlage für meine eigene Stimme. Ich lese hierfür einen kurzen, gleichmäßig gesprochenen Satz vor."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tonstudio")
                    .flowFont(.caption, weight: .semibold)
                    .foregroundStyle(.tint)
                    .textCase(.uppercase)
                    .tracking(1.1)
                Text("Eigene Stimme")
                    .font(.system(size: 26, weight: .semibold, design: .serif))
            }
            .padding(.horizontal, 26)
            .padding(.top, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    referenceCard
                    PillSection("Beschreibung") {
                        PillRow(title: "Name") {
                            TextField("Name (z. B. „Meine Stimme“)", text: $name)
                                .textFieldStyle(.flow)
                                .frame(width: 240)
                        }
                        PillRow(title: "Sprache") {
                            SegmentedPills(selection: $languageCode, options: [
                                PillOption(value: "de", label: "Deutsch", verbatim: true),
                                PillOption(value: "en", label: "English", verbatim: true),
                            ])
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Wortlaut der Aufnahme (erhöht die Klangtreue deutlich)")
                                .flowFont(.callout)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $refText)
                                .font(.system(size: 13, design: .serif))
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .frame(minHeight: 80)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
                            if mode == .record && refText.isEmpty {
                                Button("Vorschlagstext übernehmen") { refText = suggestedText }
                                    .buttonStyle(FlowButtonStyle(variant: .subtle, size: .small))
                            }
                        }
                        .padding(16)
                        .flowSurface(cornerRadius: Theme.Radius.row)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .flowFont(.callout)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.never)

            HStack {
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .buttonStyle(.flowSubtle)
                Spacer()
                Button("Stimme anlegen") { save() }
                    .buttonStyle(FlowButtonStyle(variant: .prominent, size: .large))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 540, minHeight: 560)
        .background { PaperPage() }
        .navigationTitle("Eigene Stimme")
        .onDisappear {
            meterTimer?.invalidate()
            recorder?.stop()
            player?.stop()
        }
    }

    private var canSave: Bool {
        switch mode {
        case .record: return recordingURL != nil
        case .importedFile: return true
        }
    }

    private func startRecording() {
        errorMessage = nil
        stopPlayback()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookForge-clone-\(UUID().uuidString).wav")
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 24000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ]
            let newRecorder = try AVAudioRecorder(url: url, settings: settings)
            newRecorder.record()
            recorder = newRecorder
            recordingURL = url
            isRecording = true
            secondsRecorded = 0
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                secondsRecorded = recorder?.currentTime ?? 0
            }
        } catch {
            errorMessage = "Mikrofon nicht verfügbar: \(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        meterTimer?.invalidate()
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else if let recordingURL {
            do {
                let newPlayer = try AVAudioPlayer(contentsOf: recordingURL)
                newPlayer.play()
                player = newPlayer
                isPlaying = true
                DispatchQueue.main.asyncAfter(deadline: .now() + newPlayer.duration + 0.2) {
                    isPlaying = false
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    private func save() {
        let audioURL: URL?
        switch mode {
        case .record: audioURL = recordingURL
        case .importedFile(let url): audioURL = url
        }
        guard let audioURL else {
            errorMessage = "Keine Aufnahme vorhanden."
            return
        }
        do {
            let clone = try VoiceCloneStore.shared.add(
                name: name,
                refText: refText,
                languageCode: languageCode,
                audioURL: audioURL
            )
            onSaved(clone)
            dismiss()
        } catch {
            errorMessage = "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}
