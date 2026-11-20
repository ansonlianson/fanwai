import SwiftUI

private struct PlaybackTopKey: EnvironmentKey { static let defaultValue = CGFloat.infinity }
extension EnvironmentValues {
    var playbackTop: CGFloat {
        get { self[PlaybackTopKey.self] }
        set { self[PlaybackTopKey.self] = newValue }
    }
}
