//
// Wire
// Copyright (C) 2022 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//

import Foundation
import CallKit
import avs

final class CallKitManager: NSObject, CallKitManagerInterface, CXProviderDelegate {

    // MARK: - Properties

    private let callProvider: CXProvider
    private let callController: CXCallController
    private weak var mediaManager: MediaManagerType?

    // MARK: - Life cycle

    init(mediaManager: MediaManagerType) {
        callProvider = CXProvider(configuration: Self.configuration)
        callController = CXCallController(queue: .main)
        self.mediaManager = mediaManager
        super.init()
        callProvider.setDelegate(self, queue: nil)
    }

    // MARK: - Configuration

    func updateConfiguration() {
        callProvider.configuration = Self.configuration
    }

    private class var configuration: CXProviderConfiguration {
        let localizedName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Wire"
        let configuration = CXProviderConfiguration(localizedName: localizedName)
        configuration.supportsVideo = true
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.ringtoneSound = NotificationSound.call.name

        if let image = UIImage(named: "wire-logo-letter") {
            configuration.iconTemplateImageData = image.pngData()
        }

        return configuration
    }

    // MARK: - Request actions

    func requestJoinCall(in conversation: ZMConversation, hasVideo: Bool) {
        fatal("not implemented")
    }

    func requestMuteCall(in conversation: ZMConversation, isMuted: Bool) {
        fatal("not implemented")
    }

    func requestEndCall(in conversation: ZMConversation, completion: (() -> Void)?) {
        fatal("not implemented")
    }

    // MARK: - Call provider

    public func providerDidBegin(_ provider: CXProvider) {
        fatal("not implemented")
    }

    public func providerDidReset(_ provider: CXProvider) {
        fatal("not implemented")
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        fatal("not implemented")
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        fatal("not implemented")
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        fatal("not implemented")
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        fatal("not implemented")
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        fatal("not implemented")
    }

    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        fatal("not implemented")
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        fatal("not implemented")
    }

    // MARK: - Misc

    func continueUserActivity(_ userActivity: NSUserActivity) -> Bool {
        fatal("not implemented")
    }

}
