/*
 * Wire
 * Copyright (C) 2017 Wire Swiss GmbH
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import Foundation
import CallKit
import Intents
import avs


protocol CallKitManagerDelegate: AnyObject {

    /// Look a conversation where a call has or will take place

    func lookupConversation(by handle: CallHandle, completionHandler: @escaping (Result<ZMConversation>) -> Void)

    /// End all active calls in all user sessions

    func endAllCalls()

}

@objc
public class CallKitManager: NSObject {

    // MARK: - Properties

    private let provider: CXProvider
    private let callController: CXCallController
    private weak var mediaManager: MediaManagerType?

    private weak var delegate: CallKitManagerDelegate?

    private var callStateObserverToken: Any?
    private var missedCallObserverToken: Any?

    private let callRegister = CallKitCallRegister()
    private var connectedCallConversation: ZMConversation?

    // MARK: - Life cycle

    public convenience init(mediaManager: MediaManagerType) {
        self.init(
            mediaManager: mediaManager,
            delegate: nil
        )
    }

    convenience init(
        mediaManager: MediaManagerType,
        delegate: CallKitManagerDelegate?
    ) {
        self.init(
            provider: CXProvider(configuration: CallKitManager.providerConfiguration),
            callController: CXCallController(queue: DispatchQueue.main),
            mediaManager: mediaManager,
            delegate: delegate
        )
    }

    init(
        provider: CXProvider,
        callController: CXCallController,
        mediaManager: MediaManagerType?,
        delegate: CallKitManagerDelegate? = nil
    ) {
        self.provider = provider
        self.callController = callController
        self.mediaManager = mediaManager
        self.delegate = delegate

        super.init()

        provider.setDelegate(self, queue: nil)

        callStateObserverToken = WireCallCenterV3.addGlobalCallStateObserver(observer: self)
        missedCallObserverToken = WireCallCenterV3.addGlobalMissedCallObserver(observer: self)
    }

    deinit {
        provider.invalidate()
    }

    // MARK: - Configuration

    public func updateConfiguration() {
        provider.configuration = CallKitManager.providerConfiguration
    }

    static var providerConfiguration: CXProviderConfiguration {
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

    // MARK: - Logging

    private func log(
        _ message: String,
        file: String = #file,
        line: Int = #line
    ) {
        let messageWithLineNumber = String(
            format: "%@:%ld: %@",
            URL(fileURLWithPath: file).lastPathComponent,
            line,
            message
        )

        SessionManager.logAVS(message: messageWithLineNumber)
    }

    // MARK: - Actions

    private func actionsToEndAllOngoingCalls(excepting handle: CallHandle) -> [CXAction] {
        return callRegister.allCalls
            .lazy
            .filter { $0.handle != handle }
            .map { CXEndCallAction(call: $0.id) }
    }

    // MARK: - Intents

    func findConversationAssociated(with contacts: [INPerson], completion: @escaping (ZMConversation) -> Void) {

        guard contacts.count == 1,
              let contact = contacts.first,
              let customIdentifier = contact.personHandle?.value,
              let callHandle = CallHandle(encodedString: customIdentifier)
        else {
            return
        }

        delegate?.lookupConversation(by: callHandle, completionHandler: { (result) in
            guard case .success(let conversation) = result else { return }
            completion(conversation)
        })
    }

    public func continueUserActivity(_ userActivity: NSUserActivity) -> Bool {
        guard let interaction = userActivity.interaction
        else { return false }

        let intent = interaction.intent
        var contacts: [INPerson]?
        var video = false

        if let startCallIntent = intent as? INStartCallIntent {
          contacts = startCallIntent.contacts
          video = startCallIntent.callCapability == .videoCall
        }

        if let contacts = contacts {
            findConversationAssociated(with: contacts) { [weak self] (conversation) in
                self?.requestStartCall(in: conversation, video: video)
            }

            return true
        }

        return false
    }

    // MARK: - Requesting actions

    func requestMuteCall(
        in conversation: ZMConversation,
        muted: Bool
    ) {
        guard let call = callRegister.lookupCall(by: conversation) else {
            return
        }

        let action = CXSetMutedCallAction(
            call: call.id,
            muted: muted
        )

        callController.request(CXTransaction(action: action)) { [weak self] error in
            if let error = error {
                self?.log("Cannot update call to muted = \(muted): \(error)")
            }
        }
    }

    func requestJoinCall(
        in conversation: ZMConversation,
        video: Bool
    ) {
        if existsIncomingCall(in: conversation) {
            requestAnswerCall(in: conversation, video: video)
        } else {
            requestStartCall(in: conversation, video: video)
        }
    }

    private func existsIncomingCall(in conversation: ZMConversation) -> Bool {
        guard
            let call = callRegister.lookupCall(by: conversation),
            let existingCall = callController.existingCall(for: call)
        else {
            return false
        }

        return !existingCall.isOutgoing

    }

    func requestStartCall(
        in conversation: ZMConversation,
        video: Bool
    ) {
        guard
            let context = conversation.managedObjectContext,
            let handle = conversation.callHandle
        else {
            self.log("Ignore request to start call since remoteIdentifier or handle is nil")
            return
        }

        // TODO: do we need to check there doesn't already exist a call?
        let call = callRegister.registerNewCall(with: handle)

        let action = CXStartCallAction(call: call.id, handle: handle.cxHandle)
        action.isVideo = video
        action.contactIdentifier = conversation.localizedCallerName(with: ZMUser.selfUser(in: context))

        let endCallActions = actionsToEndAllOngoingCalls(excepting: handle)
        let transaction = CXTransaction(actions: endCallActions + [action])

        log("request CXStartCallAction")

        callController.request(transaction) { [weak self] error in
            if let error = error as? CXErrorCodeRequestTransactionError, error.code == .callUUIDAlreadyExists {
                self?.requestAnswerCall(in: conversation, video: video)
            } else if let error = error {
                self?.log("Cannot start call: \(error)")
            }
        }
    }

    func requestAnswerCall(in conversation: ZMConversation, video: Bool) {
        guard let call = callRegister.lookupCall(by: conversation) else { return }
        let action = CXAnswerCallAction(call: call.id)
        let endPreviousActions = actionsToEndAllOngoingCalls(excepting: call.handle)
        let transaction = CXTransaction(actions: endPreviousActions + [action])

        log("request CXAnswerCallAction")

        callController.request(transaction) { [weak self] error in
            if let error = error {
                self?.log("Cannot answer call: \(error)")
            }
        }
    }

    func requestEndCall(in conversation: ZMConversation, completion: (() -> Void)? = nil) {
        guard let call = callRegister.lookupCall(by: conversation) else { return }
        let action = CXEndCallAction(call: call.id)
        let transaction = CXTransaction(action: action)

        log("request CXEndCallAction")

        callController.request(transaction) { [weak self] error in
            if let error = error {
                self?.log("Cannot end call: \(error)")
                conversation.voiceChannel?.leave()
            }
            completion?()
        }
    }

    // MARK: - Reporting calls

    func reportIncomingCallPreemptively(
        handle: CallHandle,
        callerName: String,
        hasVideo: Bool
    ) {
        guard !callRegister.callExists(for: handle) else {
            // TODO: critical log
            return
        }

        let call = callRegister.registerNewCall(with: handle)

        let update = CXCallUpdate()
        update.localizedCallerName = callerName
        update.remoteHandle = handle.cxHandle
        update.hasVideo = hasVideo
        update.supportsHolding = false
        update.supportsDTMF = false
        update.supportsGrouping = false
        update.supportsUngrouping = false

        provider.reportNewIncomingCall(
            with: call.id,
            update: update
        ) { [weak self] error in
            if let error = error {
                self?.log("Cannot preemptively report incoming call: \(error)")
                self?.callRegister.unregisterCall(call)
            }
        }
    }

    func reportCallEndedPreemptively(
        handle: CallHandle,
        reason: CXCallEndedReason
    ) {
        guard let call = callRegister.lookupCall(by: handle) else {
            // TODO: critical log
            return
        }

        provider.reportCall(
            with: call.id,
            endedAt: nil,
            reason: reason
        )

        callRegister.unregisterCall(call)
    }

    /// Reports an incoming call to CallKit.
    ///
    /// - Parameters:
    ///   - user: The caller.
    ///   - conversation: The conversation in which the call is incoming.
    ///   - hasVideo: Whether the caller has video enabled.

    func reportIncomingCall(
        from user: ZMUser,
        in conversation: ZMConversation,
        hasVideo: Bool
    ) {
        // IDEA: pass in the handle, so we don't need the conversation.
        // But we would want to add the conversation to the call.
        // But when do we first use the observer? Can we add it later?
        // Only on start call action, and answer call action.
        // If we can get the observer directly in the action, then
        // we don't need them here.

        guard let handle = conversation.callHandle else {
            log("Cannot report incoming call: conversation is missing handle")
            return
        }

        guard !callRegister.callExists(for: handle)  else {
            log("Cannot report incoming call: call already exists, probably b/c it was reported earlier for a push notification")
            return
        }

        let update = CXCallUpdate()
        update.localizedCallerName = conversation.localizedCallerName(with: user)
        update.remoteHandle = handle.cxHandle
        update.hasVideo = hasVideo
        update.supportsHolding = false
        update.supportsDTMF = false
        update.supportsGrouping = false
        update.supportsUngrouping = false

        let call = callRegister.registerNewCall(with: handle)

        log("provider.reportNewIncomingCall")

        provider.reportNewIncomingCall(
            with: call.id,
            update: update
        ) { [weak self] error in
            if let error = error {
                self?.log("Cannot report incoming call: \(error)")
                self?.callRegister.unregisterCall(call)
                conversation.voiceChannel?.leave()
            } else {
                self?.mediaManager?.setupAudioDevice()
            }
        }
    }

    /// Reports to CallKit all calls associated with a conversation as ended.
    ///
    /// - Parameters:
    ///   - conversation: The conversation in which the call(s) ended.
    ///   - timestamp: The date at which the call(s) ended.
    ///   - reason: The reason why the call(s) ended.

    func reportCallEnded(
        in conversation: ZMConversation,
        atTime timestamp: Date?,
        reason: CXCallEndedReason
    ) {
        let associatedCalls = callRegister.allCalls.filter {
            $0.handle == conversation.callHandle
        }

        associatedCalls.forEach { call in
            callRegister.unregisterCall(call)
            log("provider.reportCallEndedAt: \(String(describing: timestamp))")
            provider.reportCall(with: call.id, endedAt: timestamp?.clampForCallKit() ?? Date(), reason: reason)
        }
    }

}

// MARK: - Provider delegate

extension CallKitManager: CXProviderDelegate {

    public func providerDidBegin(_ provider: CXProvider) {
        log("providerDidBegin: \(provider)")
    }

    public func providerDidReset(_ provider: CXProvider) {
        log("providerDidReset: \(provider)")
        mediaManager?.resetAudioDevice()
        callRegister.reset()
        delegate?.endAllCalls()
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        log("perform CXStartCallAction: \(action)")

        guard let call = callRegister.lookupCall(by: action.callUUID) else {
            log("fail CXStartCallAction because call did not exist")
            action.fail()
            return
        }

        guard let delegate = delegate else {
            log("fail CXStartCallAction because can't fetch conversation")
            action.fail()
            return
        }

        delegate.lookupConversation(by: call.handle) { [weak self] result in
            guard let `self` = self else {
                action.fail()
                return
            }

            switch result {
            case .success(let conversation):
                call.observer.startObservingChanges(in: conversation)

                call.observer.onAnswered = {
                    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
                }

                call.observer.onEstablished = {
                    provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
                }

                self.mediaManager?.setupAudioDevice()

                if conversation.voiceChannel?.join(video: action.isVideo) == true {
                    action.fulfill()
                } else {
                    action.fail()
                }

                let update = CXCallUpdate()
                update.remoteHandle = call.handle.cxHandle
                update.localizedCallerName = conversation.localizedCallerNameForOutgoingCall()
                provider.reportCall(with: action.callUUID, updated: update)

            case .failure(let error):
                self.log("fail CXStartCallAction because can't fetch conversation: \(error)")
                action.fail()
            }
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        log("perform CXAnswerCallAction: \(action)")

        guard let call = callRegister.lookupCall(by: action.callUUID) else {
            log("fail CXAnswerCallAction because call did not exist")
            action.fail()
            return
        }

        guard let delegate = delegate else {
            log("fail CXAnswerCallAction because can't fetch conversation")
            action.fail()
            return
        }

        delegate.lookupConversation(by: call.handle) { [weak self] result in
            guard let `self` = self else {
                action.fail()
                return
            }

            switch result {
            case .success(let conversation):
                call.observer.startObservingChanges(in: conversation)

                call.observer.onEstablished = {
                    action.fulfill()
                }

                call.observer.onFailedToJoin = {
                    action.fail()
                }

                if conversation.voiceChannel?.join(video: false) != true {
                    action.fail()
                }

            case .failure(let error):
                self.log("fail CXAnswerCallAction because can't fetch conversation: \(error)")
                action.fail()
            }
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        log("perform CXEndCallAction: \(action)")

        guard let call = callRegister.lookupCall(by: action.callUUID) else {
            log("fail CXEndCallAction because call did not exist")
            action.fail()
            return
        }

        callRegister.unregisterCall(call)

        guard let delegate = delegate else {
            log("fail CXEndCallAction because can't fetch conversation")
            action.fail()
            return
        }

        delegate.lookupConversation(by: call.handle) { [weak self] result in
            guard let `self` = self else {
                action.fail()
                return
            }

            switch result {
            case .success(let conversation):
                conversation.voiceChannel?.leave()
                action.fulfill()

            case .failure(let error):
                self.log("fail CXEndCallAction because can't fetch conversation: \(error)")
                action.fail()
            }
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        log("perform CXSetHeldCallAction: \(action)")

        guard let call = callRegister.lookupCall(by: action.callUUID) else {
            log("fail CXSetHeldCallAction because call did not exist")
            action.fail()
            return
        }

        guard let delegate = delegate else {
            log("fail CXSetHeldCallAction because can't fetch conversation")
            action.fail()
            return
        }

        delegate.lookupConversation(by: call.handle) { [weak self] result in
            guard let `self` = self else {
                action.fail()
                return
            }

            switch result {
            case .success(let conversation):
                conversation.voiceChannel?.muted = action.isOnHold
                action.fulfill()

            case .failure(let error):
                self.log("fail CXSetHeldCallAction because can't fetch conversation: \(error)")
                action.fail()
            }
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        log("perform CXSetMutedCallAction: \(action)")

        guard let call = callRegister.lookupCall(by: action.callUUID) else {
            log("fail CXSetMutedCallAction because call did not exist")
            action.fail()
            return
        }

        guard let delegate = delegate else {
            log("fail CXSetMutedCallAction because can't fetch conversation")
            action.fail()
            return
        }

        delegate.lookupConversation(by: call.handle) { [weak self] result in
            guard let `self` = self else {
                action.fail()
                return
            }

            switch result {
            case .success(let conversation):
                conversation.voiceChannel?.muted = action.isMuted
                action.fulfill()

            case .failure(let error):
                self.log("fail CXSetMutedCallAction because can't fetch conversation: \(error)")
                action.fail()
            }
        }
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        log("didActivate audioSession")
        mediaManager?.startAudio()
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        log("didDeactivate audioSession")
        mediaManager?.resetAudioDevice()
    }

}

// MARK: - Callstate observer

extension CallKitManager: WireCallCenterCallStateObserver, WireCallCenterMissedCallObserver {

    public func callCenterDidChange(
        callState: CallState,
        conversation: ZMConversation,
        caller: UserType,
        timestamp: Date?,
        previousCallState: CallState?
    ) {
        switch callState {
        case .incoming(let hasVideo, let shouldRing, degraded: _):
            if shouldRing {
                guard
                    let caller = caller as? ZMUser,
                    conversation.mutedMessageTypesIncludingAvailability == .none,
                    !conversation.needsToBeUpdatedFromBackend
                else {
                    // TODO: log
                    return
                }

                reportIncomingCall(
                    from: caller,
                    in: conversation,
                    hasVideo: hasVideo
                )

            } else {
                reportCallEnded(
                    in: conversation,
                    atTime: timestamp,
                    reason: .unanswered
                )
            }

        case .terminating(let reason):
            reportCallEnded(
                in: conversation,
                atTime: timestamp,
                reason: reason.CXCallEndedReason
            )

        default:
            break
        }
    }


    public func callCenterMissedCall(conversation: ZMConversation, caller: UserType, timestamp: Date, video: Bool) {
        // Since we missed the call we will not have an assigned callUUID and can just create a random one
        provider.reportCall(with: UUID(), endedAt: timestamp, reason: .unanswered)
    }

}

// MARK: - Helpers

private extension Date {

    func clampForCallKit() -> Date {
        let twoWeeksBefore = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
        return clamp(between: twoWeeksBefore, and: Date())
    }

    func clamp(between fromDate: Date, and toDate: Date) -> Date {
        if timeIntervalSinceReferenceDate < fromDate.timeIntervalSinceReferenceDate {
            return fromDate
        } else if timeIntervalSinceReferenceDate > toDate.timeIntervalSinceReferenceDate {
            return toDate
        } else {
            return self
        }
    }
}

extension ZMConversation {

    var callHandle: CallHandle? {
        guard
            let context = managedObjectContext,
            let userID = ZMUser.selfUser(in: context).remoteIdentifier,
            let conversationID = remoteIdentifier
        else {
            return nil
        }

        return CallHandle(
            accountID: userID,
            conversationID: conversationID
        )
    }

    func localizedCallerNameForOutgoingCall() -> String? {
        guard let managedObjectContext = self.managedObjectContext  else { return nil }

        return localizedCallerName(with: ZMUser.selfUser(in: managedObjectContext))
    }

    func localizedCallerName(with user: ZMUser) -> String {

        let conversationName = self.userDefinedName
        let callerName: String? = user.name
        var result: String?

        switch conversationType {
        case .group:
            if let conversationName = conversationName, let callerName = callerName {
                result = String.localizedStringWithFormat("callkit.call.started.group".pushFormatString, callerName, conversationName)
            } else if let conversationName = conversationName {
                result = String.localizedStringWithFormat("callkit.call.started.group.nousername".pushFormatString, conversationName)
            } else if let callerName = callerName {
                result = String.localizedStringWithFormat("callkit.call.started.group.noconversationname".pushFormatString, callerName)
            }
        case .oneOnOne:
            result = connectedUser?.name
        default:
            break
        }

        return result ?? String.localizedStringWithFormat("callkit.call.started.group.nousername.noconversationname".pushFormatString)
    }

}

extension CXCallAction {

    func conversation(in context: NSManagedObjectContext) -> ZMConversation? {
        return ZMConversation.fetch(with: callUUID, in: context)
    }

}

extension CallClosedReason {

    var CXCallEndedReason: CXCallEndedReason {
        switch self {
        case .timeout, .timeoutECONN:
            return .unanswered
        case .normal, .canceled:
            return .remoteEnded
        case .anweredElsewhere:
            return .answeredElsewhere
        case .rejectedElsewhere:
            return .declinedElsewhere
        default:
            return .failed
        }
    }

}

private extension CallKitCallRegister {

    func lookupCall(by conversation: ZMConversation) -> CallKitCall? {
        guard let handle = conversation.callHandle else { return nil }
        return lookupCall(by: handle)
    }

}

private extension CXCallController {

    func existingCall(for callKitCall: CallKitCall) -> CXCall? {
        return callObserver.calls.first { $0.uuid == callKitCall.id }
    }

}
