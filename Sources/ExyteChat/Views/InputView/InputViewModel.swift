//
//  Created by Alex.M on 20.06.2022.
//

import Foundation
import Combine
import ExyteMediaPicker
import SwiftUI

@MainActor
final class InputViewModel: ObservableObject {

    @Published var text = ""
    @Published var attachments = InputViewAttachments()
    @Published var state: InputViewState = .empty

    @Published var showGiphyPicker = false
    @Published var showMediaPicker = false
    @Published var showDocumentPicker = false
    @Published var showLocationPicker = false

    @Published var mediaPickerMode = MediaPickerMode.photos

    @Published var showActivityIndicator = false

    var recordingPlayer: RecordingPlayer?
    var didSendMessage: ((DraftMessage) async -> Bool)?

    private var recorder = Recorder()

    private var saveEditingClosure: ((String) -> Void)?

    private var recordPlayerSubscription: AnyCancellable?
    private var subscriptions = Set<AnyCancellable>()
    
    func setRecorderSettings(recorderSettings: RecorderSettings = RecorderSettings()) {
        let recorder = recorder
        Task {
            await recorder.setRecorderSettings(recorderSettings)
        }
    }

    func onStart() {
        guard subscriptions.isEmpty else { return }
        subscribeValidation()
        subscribeGiphyPicker()
    }

    func onStop() {
        subscriptions.removeAll()
    }

    func reset() {
        showGiphyPicker = false
        showMediaPicker = false
        showDocumentPicker = false
        showLocationPicker = false
        text = ""
        saveEditingClosure = nil
        attachments = InputViewAttachments()
        state = .empty
    }

    func send() {
        Task {
            await recorder.stopRecording()
            await recordingPlayer?.reset()
            await sendMessage()
        }
    }

    func edit(_ closure: @escaping (String) -> Void) {
        saveEditingClosure = closure
        state = .editing
    }

    func inputViewAction() -> (InputViewAction) -> Void {
        { [weak self] in
            self?.inputViewActionInternal($0)
        }
    }

    private func inputViewActionInternal(_ action: InputViewAction) {
        switch action {
        case .giphy:
            showGiphyPicker = true
        case .photo:
            mediaPickerMode = .photos
            showMediaPicker = true
        case .add:
            mediaPickerMode = .camera
        case .camera:
            mediaPickerMode = .camera
            showMediaPicker = true
        case .document:
            showDocumentPicker = true
        case .location:
            showLocationPicker = true
        case .send:
            send()
        case .recordAudioTap:
            Task {
                state = await recorder.isAllowedToRecordAudio ? .isRecordingTap : .waitingForRecordingPermission
                recordAudio()
            }
        case .recordAudioHold:
            Task {
                state = await recorder.isAllowedToRecordAudio ? .isRecordingHold : .waitingForRecordingPermission
                recordAudio()
            }
        case .recordAudioLock:
            state = .isRecordingTap
        case .stopRecordAudio:
            Task {
                await recorder.stopRecording()
                if let _ = attachments.recording {
                    state = .hasRecording
                }
                await recordingPlayer?.reset()
            }
        case .deleteRecord:
            Task {
                unsubscribeRecordPlayer()
                await recorder.stopRecording()
                attachments.recording = nil
            }
        case .playRecord:
            state = .playingRecording
            if let recording = attachments.recording {
                Task {
                    subscribeRecordPlayer()
                    await recordingPlayer?.play(recording)
                }
            }
        case .pauseRecord:
            state = .pausedRecording
            Task {
                await recordingPlayer?.pause()
            }
        case .saveEdit:
            saveEditingClosure?(text)
            reset()
        case .cancelEdit:
            reset()
        }
    }

    private func recordAudio() {
        Task { [weak self, recorder] in
            guard !(await recorder.isRecording) else { return }
            await MainActor.run {
                self?.attachments.recording = Recording()
            }
            let url = await recorder.startRecording { [weak self] duration, samples in
                Task { @MainActor in
                    self?.attachments.recording?.duration = duration
                    self?.attachments.recording?.waveformSamples = samples
                }
            }
            await MainActor.run {
                guard let self else { return }
                if self.state == .waitingForRecordingPermission {
                    self.state = .isRecordingTap
                }
                self.attachments.recording?.url = url
            }
        }
    }
}

private extension InputViewModel {

    func validateDraft() {
        guard state != .editing else { return } // special case
        let hasAttachments = !attachments.medias.isEmpty || !attachments.documents.isEmpty || attachments.staticLocation != nil || attachments.liveLocation != nil
        if !text.isEmpty || hasAttachments {
            state = .hasTextOrMedia
        } else if text.isEmpty,
                  !hasAttachments,
                  attachments.recording == nil {
            state = .empty
        }
    }

    func subscribeValidation() {
        $attachments.sink { [weak self] _ in
            self?.validateDraft()
        }
        .store(in: &subscriptions)

        $text.sink { [weak self] _ in
            self?.validateDraft()
        }
        .store(in: &subscriptions)
    }

    func subscribeGiphyPicker() {
        $showGiphyPicker
            .sink { [weak self] value in
                if !value {
                  self?.attachments.giphyMedia = nil
                }
            }
            .store(in: &subscriptions)
    }
  
    func subscribeRecordPlayer() {
        if let recordingPlayer {
            recordPlayerSubscription = recordingPlayer.didPlayTillEnd
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    self?.state = .hasRecording
                }
        }
    }

    func unsubscribeRecordPlayer() {
        recordPlayerSubscription = nil
    }
}

private extension InputViewModel {

    func sendMessage() async {
        showActivityIndicator = true
        // live location shares need a stable id upfront so subsequent location updates can find this message again
        let messageId = (attachments.liveLocation != nil) ? UUID().uuidString : nil
        let draft = DraftMessage(
            id: messageId,
            text: text,
            medias: attachments.medias,
            giphyMedia: attachments.giphyMedia,
            documents: attachments.documents,
            staticLocation: attachments.staticLocation,
            liveLocation: attachments.liveLocation,
            recording: attachments.recording,
            replyMessage: attachments.replyMessage,
            createdAt: Date()
        )

        let shouldReset = await (didSendMessage?(draft) ?? true)
        showActivityIndicator = false

        if shouldReset {
            reset()
        }
    }
}
