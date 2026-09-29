@preconcurrency import AVFoundation
import Testing

@testable import ExyteChat

struct RecordingPlayerTest {
    @Test func initializationDoesNotChangeAudioSessionCategory() async throws {
        let session = AVAudioSession.sharedInstance()
        let originalCategory = session.category
        let originalMode = session.mode
        let originalOptions = session.categoryOptions
        defer {
            try? session.setCategory(originalCategory, mode: originalMode, options: originalOptions)
        }
        try session.setCategory(.ambient)

        await MainActor.run {
            _ = RecordingPlayer()
            #expect(session.category == .ambient)
        }
    }
}
