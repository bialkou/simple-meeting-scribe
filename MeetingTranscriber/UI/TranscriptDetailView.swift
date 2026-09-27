import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct TranscriptBlock: Identifiable {
    let segments: [TranscriptSegment]

    var id: UUID { segments[0].id }
    var start: Double { segments[0].start }
    var speakerId: Int { segments[0].speakerId }
    var text: String { joinTranscriptSegments(segments) }
}

private func joinTranscriptSegments(_ segments: [TranscriptSegment]) -> String {
    var result = ""
    let punctuation = CharacterSet(charactersIn: ",.!?;:%)]}")

    for segment in segments {
        let part = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !part.isEmpty else { continue }

        if result.isEmpty,
           let first = part.unicodeScalars.first,
           punctuation.contains(first) {
            result = part
        } else if result.isEmpty {
            result = part
        } else if let first = part.unicodeScalars.first,
                  punctuation.contains(first) {
            result += part
        } else {
            result += " " + part
        }
    }

    return result
}

struct TranscriptDetailView: View {
    let documentID: String
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var renamingSpeakerID: Int? = nil
    @State private var newSpeakerNameDraft: String = ""
    @State private var splittingSpeakerID: Int? = nil
    @State private var splitSpeakerNameDraft: String = ""
    @State private var selectedSplitSegmentIDs: Set<UUID> = []
    @State private var showingAddTagPopover: Bool = false
    @State private var tagNameDraft: String = ""
    @State private var titleDraft: String = ""
    @State private var titleIsEditing: Bool = false
    @FocusState private var titleFieldFocused: Bool
    @State private var justCopied: Bool = false
    @State private var audioPlayer = TranscriptAudioPlayer()
    @State private var showingRegeneratePopover: Bool = false
    @State private var regenerationWhisperModel: WhisperModel = .defaultModel
    @State private var regenerationSummaryModel: SummaryModel?
    @State private var regenerationPrompt: String = ""
    @State private var transcriptPanelVisible: Bool = false
    @State private var transcriptSeekTime: TimeInterval?
    @State private var transcriptSeekRequestID = UUID()
    @State private var highlightedTranscriptSegmentID: UUID?
    @State private var showDateEditor: Bool = false
    @State private var recordedDraft: Date = Date()
    @State private var isExportingMixedAudio: Bool = false
    @State private var mixedAudioWasSaved: Bool = false
    /// Per-summary glossary toggle. Defaults to true whenever any glossary
    /// entry is enabled; resets on each detail-view appearance.
    @State private var useGlossaryThisRun: Bool = true
    /// Per-summary "identify speakers" toggle. Defaults to true when at least
    /// one default-named ("Remote", "Remote N") speaker still exists.
    @State private var inferSpeakerNamesThisRun: Bool = true

    private var document: TranscriptDocument? {
        appState.transcripts.first(where: { $0.id == documentID })
    }

    private var entranceAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .snappy(duration: 0.22)
    }

    private var summaryCardTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .scale(scale: 0.97).combined(with: .opacity)
    }

    private var bottomRevealTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .move(edge: .bottom))
    }

    var body: some View {
        if let doc = document {
            contentBody(for: doc)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        titlebarBlock(for: doc)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .primaryAction) {
                        exportMenu(for: doc)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .primaryAction) {
                        regenerateControl(for: doc)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .primaryAction) {
                        transcriptPanelButton()
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                .onAppear {
                    titleDraft = doc.title
                    titleIsEditing = false
                    titleFieldFocused = false
                    loadAudioIfAvailable(for: doc)
                    useGlossaryThisRun = appState.glossaryTerms.contains(where: \.isEnabled)
                    inferSpeakerNamesThisRun = doc.speakers.contains { Self.hasDefaultRemoteName($0.name) }
                    prepareRegenerationDefaults(for: doc)
                }
                .onDisappear { audioPlayer.unload() }
        } else {
            ContentUnavailableView(
                "Transcript not found",
                systemImage: "text.magnifyingglass",
                description: Text("It may have been moved or deleted.")
            )
        }
    }

    private func loadAudioIfAvailable(for doc: TranscriptDocument) {
        if let voice = TranscriptStore.shared.audioURL(for: doc) {
            let system = TranscriptStore.shared.systemAudioURL(for: doc)
            audioPlayer.load(voiceURL: voice, systemURL: system)
            if let video = TranscriptStore.shared.videoURL(for: doc) {
                audioPlayer.attachVideo(url: video, offset: doc.videoStartOffset ?? 0)
            }
        } else {
            audioPlayer.unload()
        }
    }

    private func prepareRegenerationDefaults(for doc: TranscriptDocument) {
        regenerationWhisperModel = WhisperModel.allCases.first {
            $0.shortName == doc.modelShortName
        } ?? appState.selectedModel
        regenerationSummaryModel = doc.summaryModelOverride
            ?? appState.defaultSummaryModel(for: doc.language)
        regenerationPrompt = ""
    }

    @ViewBuilder
    private func contentBody(for doc: TranscriptDocument) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                summaryColumn(for: doc)

                if transcriptPanelVisible {
                    Divider()
                    transcriptPanel(for: doc)
                        .frame(minWidth: 320, idealWidth: 390, maxWidth: 460)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            if audioPlayer.url != nil {
                bottomPlayerBar()
            }
        }
        .background(.background)
        .animation(entranceAnimation, value: transcriptPanelVisible)
    }

    @ViewBuilder
    private func summaryColumn(for doc: TranscriptDocument) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if audioPlayer.videoURL != nil {
                        VideoPlayerCard(player: audioPlayer, showsTransport: false)
                    }
                    documentDetailsBlock(for: doc)
                    speakersBlock(for: doc)
                    tagsBlock(for: doc)
                    summaryBlock(for: doc)
                }
                .padding(.horizontal, 44)
                .padding(.vertical, 24)
                .frame(maxWidth: 1020, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func transcriptPanelButton() -> some View {
        Button {
            withAnimation(entranceAnimation) {
                transcriptPanelVisible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.right")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityLabel(transcriptPanelVisible ? "Hide transcript" : "Show transcript")
        .help(transcriptPanelVisible ? "Hide transcript" : "Show transcript")
    }

    @ViewBuilder
    private func titlebarBlock(for doc: TranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Group {
                if titleIsEditing {
                    TextField("Title", text: $titleDraft)
                        .focused($titleFieldFocused)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .tracking(-0.4)
                        .textFieldStyle(.plain)
                        .lineLimit(1)
                        .onAppear { titleFieldFocused = true }
                        .onSubmit { finishTitleEditing() }
                        .onExitCommand { finishTitleEditing() }
                } else {
                    Text(titleDraft.isEmpty ? "Title" : titleDraft)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .tracking(-0.4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                        .allowsTightening(true)
                        .contentShape(Rectangle())
                        .onTapGesture { titleIsEditing = true }
                        .accessibilityLabel("Title: \(titleDraft)")
                }
            }
            .frame(minWidth: 220, maxWidth: 640, alignment: .leading)
            .frame(height: 24)

            HStack(spacing: Theme.space3) {
                Button {
                    recordedDraft = doc.displayDate
                    showDateEditor = true
                } label: {
                    Label(dateLabelText(for: doc), systemImage: "calendar")
                }
                .buttonStyle(.pressable)
                .labelStyle(.titleAndIcon)
                .help(doc.recordedAt != nil
                      ? "Recorded \(doc.displayDate.formatted(date: .abbreviated, time: .omitted)) · transcribed \(doc.date.formatted(date: .abbreviated, time: .shortened)). Click to edit."
                      : "Transcribed \(doc.date.formatted(date: .abbreviated, time: .shortened)). Click to set the recording date.")
                .popover(isPresented: $showDateEditor, arrowEdge: .bottom) {
                    dateEditorPopover(for: doc)
                }
                Text("·")
                Label(formatDuration(doc.duration), systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minWidth: 220, maxWidth: 640, alignment: .leading)
    }

    private func finishTitleEditing() {
        appState.renameTranscript(id: documentID, to: titleDraft)
        titleFieldFocused = false
        titleIsEditing = false
    }

    @ViewBuilder
    private func documentDetailsBlock(for doc: TranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            if let src = doc.sourceURL, !src.isEmpty {
                HStack(spacing: Theme.space3) {
                    Text("·")
                    if doc.sourceKind == .imported {
                        Label(src, systemImage: "tray.and.arrow.down")
                            .lineLimit(1)
                    } else if let u = URL(string: src) {
                        Link(destination: u) {
                            Label(u.host ?? src, systemImage: "link")
                        }
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }

            if doc.hasPartialSystemCapture, let silent = doc.systemAudioSilentFraction {
                Label {
                    Text("Partial capture — no system audio for \(Int((silent * 100).rounded()))% of this recording. The other participants are likely missing from parts of the transcript.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Keep both the date and time visible in the titlebar metadata.
    private func dateLabelText(for doc: TranscriptDocument) -> String {
        doc.displayDate.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private func dateEditorPopover(for doc: TranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: Theme.space6) {
            Text("Recording date")
                .font(.headline)
            DatePicker("", selection: $recordedDraft, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                if doc.recordedAt != nil {
                    Button("Clear") {
                        appState.setRecordedAt(nil, for: documentID)
                        showDateEditor = false
                    }
                }
                Spacer()
                Button("Set") {
                    appState.setRecordedAt(recordedDraft, for: documentID)
                    showDateEditor = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 300)
    }

    // MARK: – Speakers
    @ViewBuilder
    private func speakersBlock(for doc: TranscriptDocument) -> some View {
        if !doc.speakers.isEmpty {
            HStack(spacing: Theme.space4) {
                ForEach(doc.speakers) { sp in
                    speakerChip(sp, in: doc)
                }
                Spacer()
            }
        }
    }

    private func speakerChip(_ sp: SpeakerLabel, in doc: TranscriptDocument) -> some View {
        Menu {
            Button("Rename") {
                renamingSpeakerID = sp.id
                newSpeakerNameDraft = sp.name
            }

            if doc.speakers.count > 1 {
                Menu("Merge into…") {
                    ForEach(doc.speakers.filter { $0.id != sp.id }) { target in
                        Button {
                            appState.mergeSpeakers(transcriptID: documentID,
                                                   sourceID: sp.id,
                                                   into: target.id)
                        } label: {
                            HStack(spacing: Theme.space3) {
                                Circle()
                                    .fill(speakerTint(for: target.id))
                                    .frame(width: 8, height: 8)
                                Text(target.name)
                            }
                        }
                    }
                }
            }

            Divider()
            let segmentCount = doc.segments.filter { $0.speakerId == sp.id }.count
            Button("Split selected segments…") {
                splitSpeakerNameDraft = "\(sp.name) 2"
                selectedSplitSegmentIDs = []
                splittingSpeakerID = sp.id
            }
            .disabled(segmentCount < 2)
        } label: {
            HStack(spacing: Theme.space3) {
                Circle()
                    .fill(speakerTint(for: sp.id))
                    .frame(width: 8, height: 8)
                Text(sp.name)
            }
            .padding(.horizontal, Theme.space6)
            .padding(.vertical, 5)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .chipHover()
        .help("Rename, merge, or split this speaker")
        .popover(isPresented: Binding(
            get: { renamingSpeakerID == sp.id },
            set: { if !$0, renamingSpeakerID == sp.id { renamingSpeakerID = nil } }
        )) {
            renamePopover(for: sp)
        }
        .popover(isPresented: Binding(
            get: { splittingSpeakerID == sp.id },
            set: { if !$0, splittingSpeakerID == sp.id { splittingSpeakerID = nil } }
        )) {
            splitPopover(for: sp, in: doc)
        }
    }

    @ViewBuilder
    private func renamePopover(for sp: SpeakerLabel) -> some View {
        VStack(spacing: 10) {
            TextField("Name", text: $newSpeakerNameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { commitSpeakerRename(id: sp.id) }
            HStack {
                Button("Cancel") { renamingSpeakerID = nil }
                Spacer()
                Button("Save") { commitSpeakerRename(id: sp.id) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.space6)
    }

    private func commitSpeakerRename(id: Int) {
        appState.renameSpeaker(transcriptID: documentID,
                               speakerID: id,
                               to: newSpeakerNameDraft)
        renamingSpeakerID = nil
    }

    @ViewBuilder
    private func splitPopover(for sp: SpeakerLabel,
                              in doc: TranscriptDocument) -> some View {
        let segments = doc.segments.filter { $0.speakerId == sp.id }
        let canSplit = !splitSpeakerNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedSplitSegmentIDs.isEmpty
            && selectedSplitSegmentIDs.count < segments.count

        VStack(alignment: .leading, spacing: Theme.space6) {
            Text("Split \(sp.name)")
                .font(.headline)
            Text("Select the segments that belong to another person.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("New speaker name", text: $splitSpeakerNameDraft)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.space3) {
                    ForEach(segments) { segment in
                        Toggle(isOn: Binding(
                            get: { selectedSplitSegmentIDs.contains(segment.id) },
                            set: { selected in
                                if selected {
                                    selectedSplitSegmentIDs.insert(segment.id)
                                } else {
                                    selectedSplitSegmentIDs.remove(segment.id)
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(formatTimestamp(segment.start))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(segment.text)
                                    .lineLimit(2)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(width: 360)
            .frame(maxHeight: 300)

            HStack {
                Button("Cancel") { splittingSpeakerID = nil }
                Spacer()
                Button("Split") { commitSpeakerSplit(id: sp.id) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSplit)
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private func commitSpeakerSplit(id: Int) {
        appState.splitSpeaker(transcriptID: documentID,
                              speakerID: id,
                              segmentIDs: selectedSplitSegmentIDs,
                              newName: splitSpeakerNameDraft)
        selectedSplitSegmentIDs = []
        splittingSpeakerID = nil
    }

    // MARK: – Tags
    @ViewBuilder
    private func tagsBlock(for doc: TranscriptDocument) -> some View {
        HStack(spacing: Theme.space4) {
            ForEach(doc.tags, id: \.self) { tagName in
                assignedTagChip(tagName)
            }

            Button {
                tagNameDraft = ""
                showingAddTagPopover = true
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(width: 14, height: 14)
                    .padding(.horizontal, Theme.space3)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .chipHover()
            .help("Add tag")
            .popover(isPresented: $showingAddTagPopover, arrowEdge: .bottom) {
                addTagPopover()
            }

            Spacer()
        }
    }

    private func assignedTagChip(_ tagName: String) -> some View {
        Button {
            removeTag(tagName)
        } label: {
            HStack(spacing: Theme.space3) {
                Circle()
                    .fill(appState.color(for: tagName).swiftUIColor)
                    .frame(width: 8, height: 8)
                Text(tagName)
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.space6)
            .padding(.vertical, 5)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .chipHover()
        .help("Remove \(tagName)")
    }

    @ViewBuilder
    private func addTagPopover() -> some View {
        let suggestions = tagSuggestions()
        let canCreate = canCreateDraftTag()
        VStack(alignment: .leading, spacing: 10) {
            Text("Add tag")
                .font(.headline)
            TextField("Tag name", text: $tagNameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { commitTagDraft() }

            if !suggestions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.space2) {
                        ForEach(suggestions) { tag in
                            Button {
                                addTag(tag.name)
                            } label: {
                                HStack(spacing: Theme.space4) {
                                    Circle()
                                        .fill(tag.color.swiftUIColor)
                                        .frame(width: 8, height: 8)
                                    Text(tag.name)
                                    Spacer()
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.pressable)
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            if canCreate {
                Button {
                    commitTagDraft()
                } label: {
                    HStack(spacing: Theme.space4) {
                        Circle()
                            .fill(nextAutoTagColor.swiftUIColor)
                            .frame(width: 8, height: 8)
                        Text("Create “\(trimmedTagDraft)”")
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.pressable)
            }

            HStack {
                Spacer()
                Button("Done") {
                    showingAddTagPopover = false
                    tagNameDraft = ""
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.space6)
    }

    private var trimmedTagDraft: String {
        TagStore.cleanName(tagNameDraft)
    }

    private var nextAutoTagColor: TagColor {
        TagColor.allCases[appState.tagCatalog.count % TagColor.allCases.count]
    }

    /// Tags currently assigned to this transcript, read live from the store by
    /// the stable `documentID`. Never use a captured `doc` snapshot here: the
    /// add-tag popover holds its `doc` from presentation time, so a snapshot
    /// goes stale and makes `setTags` operate on outdated tags.
    private var currentTags: [String] {
        document?.tags ?? []
    }

    private func tagSuggestions() -> [Tag] {
        let assignedKeys = Set(currentTags.map { TagStore.key(for: $0) })
        let query = TagStore.key(for: tagNameDraft)
        return appState.tagCatalog.filter { tag in
            let key = TagStore.key(for: tag.name)
            guard !assignedKeys.contains(key) else { return false }
            return query.isEmpty || key.contains(query)
        }
    }

    private func canCreateDraftTag() -> Bool {
        let name = trimmedTagDraft
        let key = TagStore.key(for: name)
        guard !name.isEmpty,
              !currentTags.contains(where: { TagStore.key(for: $0) == key })
        else { return false }
        return !appState.tagCatalog.contains(where: { TagStore.key(for: $0.name) == key })
    }

    private func commitTagDraft() {
        let name = trimmedTagDraft
        guard !name.isEmpty else { return }
        addTag(name)
    }

    private func addTag(_ name: String) {
        appState.setTags(currentTags + [name], for: documentID)
        tagNameDraft = ""
        showingAddTagPopover = false
    }

    private func removeTag(_ name: String) {
        let key = TagStore.key(for: name)
        appState.setTags(currentTags.filter { TagStore.key(for: $0) != key }, for: documentID)
    }

    // MARK: – Regenerate

    private var isSummarizingThis: Bool {
        appState.summarizingTranscriptID == documentID && appState.summarizationStage.isActive
    }

    private var currentSummaryErrorMessage: String? {
        guard case .error(let msg) = appState.summarizationStage,
              appState.summarizingTranscriptID == documentID
        else { return nil }
        return msg
    }

    @ViewBuilder
    private func regenerateControl(for doc: TranscriptDocument) -> some View {
        if isSummarizingThis {
            Button(role: .destructive) {
                appState.cancelSummarization()
            } label: {
                Label("Cancel", systemImage: "stop.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        } else if let job = activeRetranscribeJob {
            HStack(spacing: Theme.space3) {
                ProgressView().controlSize(.small)
                Text(retranscribeProgressLabel(for: job))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Button {
                prepareRegenerationDefaults(for: doc)
                showingRegeneratePopover = true
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Color.accentColor, in: Circle())
            .contentShape(Circle())
            .accessibilityLabel(doc.summary?.isEmpty == false ? "Regenerate" : "Generate")
            .help("Choose local transcription and summary models, then run again")
            .popover(isPresented: $showingRegeneratePopover, arrowEdge: .top) {
                regeneratePopover(for: doc)
            }
        }
    }

    /// True for the generator-assigned defaults `"Remote"` and `"Remote N"`.
    /// User-edited names never match.
    private static func hasDefaultRemoteName(_ name: String) -> Bool {
        if name == "Remote" { return true }
        guard name.hasPrefix("Remote "), name.count > 7 else { return false }
        return name.dropFirst(7).allSatisfy(\.isNumber)
    }

    // MARK: – Re-transcribe

    /// Currently running re-transcription job for this document, if any —
    /// lets the button flip into a progress state.
    private var activeRetranscribeJob: AppState.ProcessingJob? {
        appState.processingJobs.first(where: { $0.replacingDocumentID == documentID })
    }

    private func retranscribeProgressLabel(for job: AppState.ProcessingJob) -> String {
        switch job.stage {
        case .queued:                         return "Queued for re-transcription"
        case .running(let p, let stage):      return "\(stage) · \(Int(p * 100))%"
        case .failed(let msg):                return "Failed: \(msg)"
        }
    }

    private func regeneratePopover(for doc: TranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: Theme.space6) {
            Text("Regenerate")
                .font(.headline)

            VStack(alignment: .leading, spacing: Theme.space3) {
                Picker("Transcription model", selection: $regenerationWhisperModel) {
                    ForEach(WhisperModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                Picker("Summary model", selection: summaryModelBinding(for: doc)) {
                    ForEach(summaryModels(for: doc), id: \.self) { model in
                        Text(appState.displayName(for: model)).tag(model)
                    }
                }
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: Theme.space3) {
                HStack {
                    Text("Prompt")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Load default") {
                        regenerationPrompt = SummaryPrompts.summaryInstruction(for: doc.language)
                    }
                    .buttonStyle(.link)
                    Button("Clear") {
                        regenerationPrompt = ""
                    }
                    .buttonStyle(.link)
                }

                ZStack(alignment: .topLeading) {
                    if regenerationPrompt.isEmpty {
                        Text("Optional: replace the summary instruction for this run")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                    }
                    TextEditor(text: $regenerationPrompt)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(2)
                }
                .frame(height: 116)
                .background(Theme.panelFill, in: RoundedRectangle(cornerRadius: Theme.radiusSmall,
                                                                   style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                        .stroke(Theme.panelBorder, lineWidth: 0.7)
                }
            }

            if appState.glossaryTerms.contains(where: \.isEnabled) {
                Toggle("Use glossary", isOn: $useGlossaryThisRun)
            }
            if doc.speakers.contains(where: { Self.hasDefaultRemoteName($0.name) }) {
                Toggle("Identify speakers", isOn: $inferSpeakerNamesThisRun)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showingRegeneratePopover = false
                }
                .keyboardShortcut(.cancelAction)
                Button(doc.summary?.isEmpty == false ? "Regenerate" : "Generate") {
                    runRegeneration(for: doc)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 430)
    }

    private func summaryModels(for doc: TranscriptDocument) -> [SummaryModel] {
        var models: [SummaryModel] = LanguageModel.allCases
            .filter { $0.supportedLanguages.contains(doc.language) }
            .map { SummaryModel.local($0) }
        models += appState.customSummaryModels.map(SummaryModel.custom)

        let selected = regenerationSummaryModel
            ?? doc.summaryModelOverride
            ?? appState.defaultSummaryModel(for: doc.language)
        if !models.contains(selected) {
            models.append(selected)
        }
        return models
    }

    private func summaryModelBinding(for doc: TranscriptDocument) -> Binding<SummaryModel> {
        Binding(
            get: {
                regenerationSummaryModel
                    ?? doc.summaryModelOverride
                    ?? appState.defaultSummaryModel(for: doc.language)
            },
            set: { regenerationSummaryModel = $0 }
        )
    }

    private func runRegeneration(for doc: TranscriptDocument) {
        let model = regenerationSummaryModel
            ?? doc.summaryModelOverride
            ?? appState.defaultSummaryModel(for: doc.language)
        let defaultModel = appState.defaultSummaryModel(for: doc.language)
        appState.setSummaryModelOverride(model == defaultModel ? nil : model, for: documentID)

        let prompt = regenerationPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        showingRegeneratePopover = false

        if regenerationWhisperModel.shortName != doc.modelShortName,
           TranscriptStore.shared.audioURL(for: doc) != nil {
            appState.retranscribe(
                documentID: documentID,
                with: regenerationWhisperModel,
                summaryModel: model,
                customSummaryInstruction: prompt.isEmpty ? nil : prompt,
                useGlossary: useGlossaryThisRun,
                inferSpeakerNames: inferSpeakerNamesThisRun
            )
        } else {
            appState.summarize(
                transcriptID: documentID,
                customSummaryInstruction: prompt.isEmpty ? nil : prompt,
                model: model,
                useGlossary: useGlossaryThisRun,
                inferSpeakerNames: inferSpeakerNamesThisRun
            )
        }
    }

    // MARK: – Summary block (streaming + saved)

    @ViewBuilder
    private func summaryBlock(for doc: TranscriptDocument) -> some View {
        let summaryErrorMessage = currentSummaryErrorMessage

        Group {
            if isSummarizingThis {
                liveStreamingBlock()
                    .transition(summaryCardTransition)
            } else {
                // A failed Regenerate keeps the previous summary, so show the
                // error above it rather than hiding it.
                if let msg = summaryErrorMessage {
                    summaryErrorBlock(msg)
                        .transition(summaryCardTransition)
                }
                if doc.summary?.isEmpty == false {
                    savedSummaryBlock(for: doc)
                }
            }
        }
        .animation(entranceAnimation, value: isSummarizingThis)
        .animation(entranceAnimation, value: summaryErrorMessage != nil)
    }

    @ViewBuilder
    private func liveStreamingBlock() -> some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: Theme.space6) {
                switch appState.summarizationStage {
                case .loadingModel(let fraction):
                    Label("Loading model…", systemImage: "arrow.down.circle")
                        .font(.headline)
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)

                case .identifyingSpeakers:
                    Label("Identifying speakers…", systemImage: "person.text.rectangle")
                        .font(.headline)
                    HStack(spacing: Theme.space4) {
                        ProgressView().controlSize(.small)
                        Text("Reading transcript…").foregroundStyle(.secondary)
                    }

                case .polishingTranscript:
                    Label("Polishing transcript…", systemImage: "text.badge.checkmark")
                        .font(.headline)
                    HStack(spacing: Theme.space4) {
                        ProgressView().controlSize(.small)
                        Text("Correcting obvious recognition errors…")
                            .foregroundStyle(.secondary)
                    }

                case .generatingSummary(let text):
                    Label("Summary", systemImage: "sparkles")
                        .font(Theme.sectionTitleFont)
                    streamingText(text, placeholder: "Generating…")

                case .generatingTitle(let summary):
                    Label("Summary", systemImage: "sparkles")
                        .font(Theme.sectionTitleFont)
                    Text(markdown: summary).textSelection(.enabled)
                    Divider()
                    HStack(spacing: Theme.space4) {
                        ProgressView().controlSize(.small)
                        Text("Titling…").foregroundStyle(.secondary)
                    }

                default:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private func streamingText(_ text: String, placeholder: String) -> some View {
        if text.isEmpty {
            HStack(spacing: Theme.space4) {
                ProgressView().controlSize(.small)
                Text(placeholder).foregroundStyle(.secondary)
            }
        } else {
            Text(markdown: text).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func savedSummaryBlock(for doc: TranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("Summary", systemImage: "sparkles")
                .font(Theme.sectionTitleFont)

            if let summary = doc.summary, !summary.isEmpty {
                summaryContent(summary, for: doc)
                    .textSelection(.enabled)
            }

            if let model = doc.summaryModelShortName,
               let when = doc.summaryGeneratedAt {
                Text("\(model) · \(when.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func summaryContent(_ summary: String, for doc: TranscriptDocument) -> some View {
        if let markup = SummaryMarkup.parse(summary, duration: doc.duration) {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(markup.sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title)
                            .font(.system(size: 23, weight: .semibold, design: .rounded))

                        if !section.body.isEmpty {
                            Text(markdown: section.body)
                                .font(.body)
                        }

                        if !section.bullets.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(section.bullets) { bullet in
                                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                                        Text("•")
                                            .foregroundStyle(.secondary)
                                        Text(markdown: bullet.text)
                                        if let timestamp = bullet.timestamp {
                                            summaryTimestampButton(timestamp)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            Text(markdown: summary)
        }
    }

    private func summaryTimestampButton(_ timestamp: TimeInterval) -> some View {
        Button {
            seekTo(timestamp, openTranscript: true)
        } label: {
            Text(formatTimestamp(timestamp))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.subtle)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .help("Open transcript at \(formatTimestamp(timestamp))")
    }

    private func copySummaryMarkdown(_ doc: TranscriptDocument) {
        guard let md = TranscriptFormatter.renderSummaryMarkdown(doc) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(md, forType: .string)
    }

    @ViewBuilder
    private func summaryErrorBlock(_ msg: String) -> some View {
        GlassCard(padding: Theme.space8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: Theme.space2) {
                    Text("Summarization failed").font(.headline)
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button {
                    appState.dismissSummarizationError()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.pressable)
                .help("Dismiss")
            }
        }
    }


    // MARK: – Transcript
    @ViewBuilder
    private func transcriptPanel(for doc: TranscriptDocument) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Transcript")
                    .font(Theme.sectionTitleFont)
                Text("·")
                    .foregroundStyle(.tertiary)
                let blockCount = transcriptBlocks(for: doc).count
                Text("\(blockCount) block\(blockCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(entranceAnimation) {
                        transcriptPanelVisible = false
                    }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.pressable)
                .help("Hide transcript")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    transcriptSegments(for: doc)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear {
                    if let time = transcriptSeekTime {
                        revealTranscriptSegment(to: time, in: doc, using: proxy)
                    }
                }
                .onChange(of: transcriptSeekRequestID) { _, _ in
                    guard let time = transcriptSeekTime else { return }
                    revealTranscriptSegment(to: time, in: doc, using: proxy)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.panelFill)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.panelBorder)
                .frame(width: 0.7)
        }
    }

    @ViewBuilder
    private func transcriptSegments(for doc: TranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(transcriptBlocks(for: doc)) { block in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Button {
                        seekTo(block.start, openTranscript: false)
                    } label: {
                        Text(formatTimestamp(block.start))
                            .font(Theme.monoFont)
                            .monospacedDigit()
                            .foregroundStyle(audioPlayer.url != nil
                                             ? AnyShapeStyle(Theme.accent)
                                             : AnyShapeStyle(.tertiary))
                            .frame(width: 72, alignment: .leading)
                    }
                    .buttonStyle(.pressable)
                    .disabled(audioPlayer.url == nil)
                    .help(audioPlayer.url != nil ? "Play from here" : "")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(speakerName(for: block.speakerId, in: doc))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(speakerTint(for: block.speakerId))
                        Text(block.text)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    transcriptBlockIsHighlighted(block)
                        ? Theme.accent.opacity(0.12)
                        : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.radiusSmall,
                                         style: .continuous)
                )
                .id(block.id)
            }
        }
    }

    private func transcriptBlocks(for doc: TranscriptDocument) -> [TranscriptBlock] {
        guard let first = doc.segments.first else { return [] }

        var grouped: [[TranscriptSegment]] = []
        var current = [first]

        for segment in doc.segments.dropFirst() {
            guard let previous = current.last else { continue }

            let gap = segment.start - previous.end
            let currentLength = current.reduce(0) { $0 + $1.text.count }
            let isNewSpeaker = segment.speakerId != previous.speakerId
            // Whisper often leaves a 3–6 second gap inside one sentence.
            // Prefer coherent same-speaker thoughts over acoustic chunks.
            let hasMeaningfulPause = gap > 8
            let completedThought = currentLength >= 48
                && textEndsThought(previous.text)
                && gap > 1.25
            let reachedSoftLimit = current.count >= 16
                || currentLength + segment.text.count > 420
                || segment.start - current[0].start > 45

            if isNewSpeaker || hasMeaningfulPause || completedThought || reachedSoftLimit {
                grouped.append(current)
                current = [segment]
            } else {
                current.append(segment)
            }
        }
        grouped.append(current)

        return grouped.map(TranscriptBlock.init(segments:))
    }

    private func textEndsThought(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return ".!?…".contains(last)
    }

    private func transcriptBlockIsHighlighted(_ block: TranscriptBlock) -> Bool {
        guard let highlightedTranscriptSegmentID else { return false }
        return block.segments.contains { $0.id == highlightedTranscriptSegmentID }
    }

    private func nearestSegment(
        to timestamp: TimeInterval,
        in doc: TranscriptDocument
    ) -> TranscriptSegment? {
        doc.segments.min { lhs, rhs in
            abs(lhs.start - timestamp) < abs(rhs.start - timestamp)
        }
    }

    private func revealTranscriptSegment(
        to timestamp: TimeInterval,
        in doc: TranscriptDocument,
        using proxy: ScrollViewProxy
    ) {
        guard let segment = nearestSegment(to: timestamp, in: doc) else { return }
        guard let block = transcriptBlocks(for: doc).first(where: {
            $0.segments.contains { $0.id == segment.id }
        }) else { return }
        withAnimation(entranceAnimation) {
            proxy.scrollTo(block.id, anchor: .center)
        }
        highlightedTranscriptSegmentID = segment.id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1300))
            if highlightedTranscriptSegmentID == segment.id {
                highlightedTranscriptSegmentID = nil
            }
        }
    }

    private func seekTo(_ timestamp: TimeInterval, openTranscript: Bool) {
        if audioPlayer.url != nil {
            audioPlayer.seek(to: timestamp)
            if !audioPlayer.isPlaying {
                audioPlayer.togglePlay()
            }
        }
        if openTranscript {
            withAnimation(entranceAnimation) {
                transcriptPanelVisible = true
            }
        }
        transcriptSeekTime = timestamp
        transcriptSeekRequestID = UUID()
    }

    @ViewBuilder
    private func bottomPlayerBar() -> some View {
        PlayerTransportRow(player: audioPlayer)
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Theme.panelFill)
            .overlay(alignment: .top) {
                Divider()
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Audio player")
    }

    private func exportMenu(for doc: TranscriptDocument) -> some View {
        Menu {
            Button {
                exportMarkdown(doc)
            } label: {
                Label("Save transcript as Markdown…", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])

            Button {
                copyMarkdown(doc)
            } label: {
                Label(justCopied ? "Copied transcript Markdown" : "Copy transcript Markdown",
                      systemImage: justCopied ? "checkmark.circle.fill" : "doc.on.doc")
            }
            .tint(justCopied ? .green : nil)
            .sensoryFeedback(.success, trigger: justCopied) { _, new in new }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            if doc.summary?.isEmpty == false {
                Button {
                    copySummaryMarkdown(doc)
                } label: {
                    Label("Copy summary Markdown", systemImage: "sparkles")
                }
            }

            if TranscriptStore.shared.audioURL(for: doc) != nil {
                Divider()
                Button {
                    exportMixedAudio(doc)
                } label: {
                    Label(
                        isExportingMixedAudio
                            ? "Preparing MP3…"
                            : mixedAudioWasSaved
                                ? "MP3 saved to Downloads"
                                : "Download mixed MP3",
                        systemImage: isExportingMixedAudio
                            ? "hourglass"
                            : mixedAudioWasSaved
                                ? "checkmark.circle.fill"
                                : "waveform.badge.arrow.down"
                    )
                }
                .disabled(isExportingMixedAudio)
                .sensoryFeedback(.success, trigger: mixedAudioWasSaved) { _, new in new }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .labelStyle(.titleAndIcon)
        .frame(minWidth: 112)
        .help("Export transcript or audio")
    }

    private func copyMarkdown(_ doc: TranscriptDocument) {
        let md = TranscriptFormatter.renderMarkdown(doc)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(md, forType: .string)
        withAnimation(.snappy) { justCopied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1600))
            withAnimation(.snappy) { justCopied = false }
        }
    }

    private func exportMarkdown(_ doc: TranscriptDocument) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = Self.sanitizeFilename(doc.title) + ".md"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let md = TranscriptFormatter.renderMarkdown(doc)
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            appState.lastError = "Could not save Markdown: \(error.localizedDescription)"
        }
    }

    private func exportMixedAudio(_ doc: TranscriptDocument) {
        guard let voiceURL = TranscriptStore.shared.audioURL(for: doc) else {
            appState.lastError = "Could not export audio: the recording is missing."
            return
        }
        guard let downloadsURL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first else {
            appState.lastError = "Could not find the Downloads folder."
            return
        }

        let systemURL = TranscriptStore.shared.systemAudioURL(for: doc)
        let filenameStem = Self.sanitizeFilename(doc.title) + "-mixed"
        isExportingMixedAudio = true
        mixedAudioWasSaved = false

        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try MixedAudioExporter.export(
                        voiceURL: voiceURL,
                        systemURL: systemURL,
                        to: downloadsURL,
                        filenameStem: filenameStem
                    )
                }.value
                isExportingMixedAudio = false
                withAnimation(.snappy) {
                    mixedAudioWasSaved = true
                }
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.snappy) {
                    mixedAudioWasSaved = false
                }
            } catch {
                isExportingMixedAudio = false
                appState.lastError = "Could not export mixed audio: \(error.localizedDescription)"
            }
        }
    }

    /// Strip characters that confuse the filesystem so doc.title can be used
    /// as a default filename. Falls back to "Transcript" for an empty result.
    private static func sanitizeFilename(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = trimmed.components(separatedBy: illegal).joined(separator: "-")
        return cleaned.isEmpty ? "Transcript" : cleaned
    }

    // MARK: – Helpers
    private func speakerName(for id: Int, in doc: TranscriptDocument) -> String {
        doc.speakers.first(where: { $0.id == id })?.name ?? "Unknown"
    }

    private func speakerTint(for id: Int) -> Color {
        if id < 0 { return .gray }
        return Theme.speakerColor(for: id)
    }

    private func formatTimestamp(_ s: Double) -> String {
        let t = Int(s)
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    private func formatDuration(_ s: TimeInterval) -> String { formatTimestamp(s) }
}
