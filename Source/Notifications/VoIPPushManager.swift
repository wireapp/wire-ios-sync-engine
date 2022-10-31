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
import PushKit
import CallKit
import avs

public protocol VoIPPushManagerDelegate: AnyObject {

    func storeVoIPToken(_ data: Data)
    func deleteExistingVoIPToken()
    func processIncomingFakeVoIPPush(payload: VoIPPushPayload, completion: @escaping () -> Void)
    func processIncomingRealVoIPPush(payload: [AnyHashable: Any], completion: @escaping () -> Void)

}

extension Logging {

    static let push = ZMSLog(tag: "Push")

}

public final class VoIPPushManager: NSObject, PKPushRegistryDelegate {

    // MARK: - Types

    class Buffer {

        var pendingActions = [PushAction]()

    }

    enum PushAction {

        case storeVoIPToken(Data)
        case deleteExistingVoIPToken
        case processIncomingRealVoIPPush(payload: [AnyHashable: Any], completion: () -> Void)
        case processIncomingFakeVoIPPush(payload: VoIPPushPayload, completion: () -> Void)

    }

    // MARK: - Properties

    let registry = PKPushRegistry(queue: nil)
    public let callKitManager: CallKitManager
    var buffer = Buffer()

    private let requiredPushTokenType: PushToken.TokenType

    private weak var delegate: VoIPPushManagerDelegate?

    // MARK: - Life cycle

    public init(requiredPushTokenType: PushToken.TokenType) {
        Logging.push.info("init PushManager")
        self.requiredPushTokenType = requiredPushTokenType
        callKitManager = CallKitManager(mediaManager: AVSMediaManager.sharedInstance())
        super.init()
        registry.delegate = self
    }

    // MARK: - Methods

    public func setDelegate(_ delegate: VoIPPushManagerDelegate) {
        self.delegate = delegate

        while !buffer.pendingActions.isEmpty {
            switch buffer.pendingActions.removeFirst() {
            case .storeVoIPToken(let data):
                delegate.storeVoIPToken(data)

            case .deleteExistingVoIPToken:
                delegate.deleteExistingVoIPToken()

            case .processIncomingRealVoIPPush(let payload, let completion):
                delegate.processIncomingRealVoIPPush(payload: payload, completion: completion)

            case .processIncomingFakeVoIPPush(let payload, let completion):
                delegate.processIncomingFakeVoIPPush(payload: payload, completion: completion)
            }
        }
    }

    public func registerForVoIPPushes() {
        Logging.push.info("registering for voIP pushes")
        registry.desiredPushTypes = [.voIP]
    }

    // Maybe we convert methods to actions, and pass those actions to a processor or buffer them.

    public func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        Logging.push.info("received updated push credentials...")

        // We're only interested in voIP tokens.
        guard type == .voIP else { return }

        // We only want to store the voip token if required.
        guard requiredPushTokenType == .voip else { return }

        if let delegate = delegate {
            Logging.push.info("fowarding to delegate")
            delegate.storeVoIPToken(pushCredentials.token)
        } else {
            Logging.push.info("buffering")
            buffer.pendingActions.append(.storeVoIPToken(pushCredentials.token))
        }
    }

    public func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        Logging.push.info("push token was invalidated...")

        // We're only interested in voIP tokens.
        guard type == .voIP else { return }

        // We don't want to delete a standard push token by accident.
        guard requiredPushTokenType == .voip else { return }

        if let delegate = delegate {
            Logging.push.info("fowarding to delegate")
            delegate.deleteExistingVoIPToken()
        } else {
            Logging.push.info("buffering")
            buffer.pendingActions.append(.deleteExistingVoIPToken)
        }
    }

    public func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        // We're only interested in voIP tokens.
        guard type == .voIP else { return completion() }

        if let nsePayload = payload.nsePayload {
            // TODO: this should only happen if the require push type is standard... guard this?
            Logging.push.info("did receive incoming fake voIP push")
            processFakePush(
                payload: nsePayload,
                completion: completion
            )
        } else {
            // TODO: this should only happen if the require push type is voip... guard this?
            Logging.push.info("did receive incoming real voIP push")
            processRealPush(
                payload: payload.dictionaryPayload,
                completion: completion
            )
        }
    }

    private func processFakePush(
        payload: VoIPPushPayload,
        completion: @escaping () -> Void
    ) {
        Logging.push.info("reporting call to CallKit")
        let handle = CallHandle(
            accountID: payload.accountID,
            conversationID: payload.conversationID
        )

        // Report the call immediately to fulfill API obligations,
        // otherwise the app will be killed. See <link>.
        // The call state observer will handle the end of the call
        if let content = CallEventContent(from: payload.data), content.isIncomingCall {
            callKitManager.reportCall(handle: handle)
        }

        if let delegate = delegate {
            Logging.push.info("fowarding to delegate")
            delegate.processIncomingFakeVoIPPush(
                payload: payload,
                completion: completion
            )
        } else {
            Logging.push.info("buffering")
            buffer.pendingActions.append(.processIncomingFakeVoIPPush(
                payload: payload,
                completion: completion
            ))
        }
    }

    private func processRealPush(
        payload: [AnyHashable: Any],
        completion: @escaping () -> Void
    ) {
        if let delegate = delegate {
            Logging.push.info("fowarding to delegate")
            delegate.processIncomingRealVoIPPush(
                payload: payload,
                completion: completion
            )
        } else {
            Logging.push.info("buffering")
            buffer.pendingActions.append(.processIncomingRealVoIPPush(
                payload: payload,
                completion: completion
            ))
        }
    }
}

// TODO: [John] remove this duplication

private extension PKPushPayload {

    var nsePayload: VoIPPushPayload? {
        guard let dict = dictionaryPayload as? [String: Any] else {
            return nil
        }

        return VoIPPushPayload(from: dict)
    }

}
