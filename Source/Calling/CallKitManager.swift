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
import WireRequestStrategy

protocol CallKitManagerDelegate: AnyObject {

    /// Look a conversation where a call has or will take place

    func lookupConversation(
        by handle: CallHandle,
        completionHandler: @escaping (Result<ZMConversation>) -> Void
    )

    func lookupConversationAndSync(
        by handle: CallHandle,
        completionHandler: @escaping (Result<ZMConversation>) -> Void
    )

    /// End all active calls in all user sessions

    func endAllCalls()

}

@objc
public protocol CallKitManagerInterface {

    var isEnabled: Bool { get set }

    func setDelegate(_ delegate: Any)
    func updateConfiguration()
    func continueUserActivity(_ userActivity: NSUserActivity) -> Bool
    func requestMuteCall(in conversation: ZMConversation, muted: Bool)
    func requestJoinCall(in conversation: ZMConversation, video: Bool)
    func requestEndCall(in conversation: ZMConversation, completion: (() -> Void)?)

}

@objc
public class CallKitManager: NSObject, CallKitManagerInterface {

    // MARK: - Properties

    public var isEnabled: Bool {
        didSet {
            VoIPPushHelper.isCallKitAvailable = isEnabled
        }
    }

    private let application: ZMApplication
    private let requirePushTokenType: PushToken.TokenType

    private let provider: CXProvider
    private let callController: CXCallController
    private weak var mediaManager: MediaManagerType?

    weak var delegate: CallKitManagerDelegate?

    private var callStateObserverToken: Any?
    private var missedCallObserverToken: Any?

    let callRegister = CallKitCallRegister()
    private var connectedCallConversation: ZMConversation?

    private static let logger = Logger(subsystem: "VoIP Push", category: "CallKitManager")

    // MARK: - Life cycle

    public convenience init(
        application: ZMApplication,
        requiredPushTokenType: PushToken.TokenType,
        mediaManager: MediaManagerType
    ) {
        self.init(
            application: application,
            requiredPushTokenType: requiredPushTokenType,
            mediaManager: mediaManager,
            delegate: nil
        )
    }

    convenience init(
        application: ZMApplication,
        requiredPushTokenType: PushToken.TokenType,
        mediaManager: MediaManagerType,
        delegate: CallKitManagerDelegate?
    ) {
        self.init(
            application: application,
            requiredPushTokenType: requiredPushTokenType,
            provider: CXProvider(configuration: CallKitManager.providerConfiguration),
            callController: CXCallController(queue: DispatchQueue.main),
            mediaManager: mediaManager,
            delegate: delegate
        )
    }

    init(
        isEnabled: Bool = false,
        application: ZMApplication,
        requiredPushTokenType: PushToken.TokenType,
        provider: CXProvider,
        callController: CXCallController,
        mediaManager: MediaManagerType?,
        delegate: CallKitManagerDelegate? = nil
    ) {
        self.isEnabled = isEnabled
        self.application = application
        self.requirePushTokenType = requiredPushTokenType
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

    // MARK: - Delegate

    public func setDelegate(_ delegate: Any) {
        // The type is any as a way to make the CallKitManagerInterface exposed to
        // objective c.
        if let delegate = delegate as? CallKitManagerDelegate {
            self.delegate = delegate
        }
    }

    // MARK: - Configuration

    public func updateConfiguration() {
        Self.logger.trace("update configuration")
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

    func findConversationAssociated(
        with contacts: [INPerson],
        completion: @escaping (ZMConversation) -> Void) {
        guard
            contacts.count == 1,
            let contact = contacts.first,
            let customIdentifier = contact.personHandle?.value,
            let callHandle = CallHandle(encodedString: customIdentifier)
        else {
            return
        }

        delegate?.lookupConversation(by: callHandle) { result in
            guard case .success(let conversation) = result else { return }
            completion(conversation)
        }
    }

    public func continueUserActivity(_ userActivity: NSUserActivity) -> Bool {
        Self.logger.trace("continue user activity")
        guard let interaction = userActivity.interaction else { return false }

        let intent = interaction.intent
        var contacts: [INPerson]?
        var video = false

        // TODO: handle INStartVideoCallIntent for when CallKit video is toggled.

        if let startCallIntent = intent as? INStartCallIntent {
          contacts = startCallIntent.contacts
          video = startCallIntent.callCapability == .videoCall
        }

        if let contacts = contacts {
            findConversationAssociated(with: contacts) { [weak self] conversation in
                self?.requestStartCall(in: conversation, video: video)
            }

            return true

        } else {
            return false
        }
    }

    // MARK: - Requesting actions

    public func requestMuteCall(
        in conversation: ZMConversation,
        muted: Bool
    ) {
        Self.logger.trace("request mute call")

        guard let call = callRegister.lookupCall(by: conversation) else {
            Self.logger.warning("fail: request mute call: call doesn't not exist")
            return
        }

        let action = CXSetMutedCallAction(
            call: call.id,
            muted: muted
        )

        callController.request(CXTransaction(action: action)) { [weak self] error in
            if let error = error {
                Self.logger.error("fail: reuqest mute call: \(error)")
                self?.log("Cannot update call to muted = \(muted): \(error)")
            }
        }
    }

    public func requestJoinCall(
        in conversation: ZMConversation,
        video: Bool
    ) {
        Self.logger.trace("request join call")

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
        Self.logger.trace("request start call")

        guard
            let context = conversation.managedObjectContext,
            let handle = conversation.callHandle
        else {
            Self.logger.warning("fail: request start call: context or handle missing")
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
                Self.logger.info("request start call: call already exists, answering...")
                self?.requestAnswerCall(in: conversation, video: video)
            } else if let error = error {
                Self.logger.error("fail: request start call: \(error)")
                self?.log("Cannot start call: \(error)")
            }
        }
    }

    func requestAnswerCall(in conversation: ZMConversation, video: Bool) {
        Self.logger.trace("request answer call")

        guard let call = callRegister.lookupCall(by: conversation) else {
            Self.logger.warning("fail: request answer call: call doesn't exist")
            return
        }

        let action = CXAnswerCallAction(call: call.id)
        let endPreviousActions = actionsToEndAllOngoingCalls(excepting: call.handle)
        let transaction = CXTransaction(actions: endPreviousActions + [action])

        log("request CXAnswerCallAction")

        callController.request(transaction) { [weak self] error in
            if let error = error {
                Self.logger.error("fail: request answer call: \(error)")
                self?.log("Cannot answer call: \(error)")
            }
        }
    }

    public func requestEndCall(
        in conversation: ZMConversation,
        completion: (() -> Void)? = nil
    ) {
        Self.logger.trace("request end call")

        guard let call = callRegister.lookupCall(by: conversation) else {
            Self.logger.warning("fail: request end call: call doesn't exist")
            return
        }

        let action = CXEndCallAction(call: call.id)
        let transaction = CXTransaction(action: action)

        log("request CXEndCallAction")

        callController.request(transaction) { [weak self] error in
            if let error = error {
                Self.logger.error("fail: request end call: \(error)")
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
        Self.logger.trace("report incoming call preemptively")

        guard !callRegister.callExists(for: handle) else {
            Self.logger.critical("fail: report incoming call preemptively: call doesn't exist")
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
                Self.logger.error("fail: report incoming call preemptively: \(error)")
                self?.log("Cannot preemptively report incoming call: \(error)")
                self?.callRegister.unregisterCall(call)
            }
        }
    }

    func reportCallEndedPreemptively(
        handle: CallHandle,
        reason: CXCallEndedReason
    ) {
        Self.logger.trace("report call ended preemptively")

        guard let call = callRegister.lookupCall(by: handle) else {
            Self.logger.critical("fail: report call ended preemptively: call doesn't exist")
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
        Self.logger.trace("report incoming call")

        guard isEnabled else {
            Self.logger.warning("fail: report incoming call: CallKit not enabled")
            return
        }

        guard let handle = conversation.callHandle else {
            Self.logger.warning("fail: report incoming call: handle doesn't exist")
            log("Cannot report incoming call: conversation is missing handle")
            return
        }

        guard !callRegister.callExists(for: handle)  else {
            Self.logger.warning("fail: report incoming call: call already exists")
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
                Self.logger.error("fail: report incoming call: \(error)")
                self?.log("Cannot report incoming call: \(error)")
                self?.callRegister.unregisterCall(call)
                conversation.voiceChannel?.leave()
            } else {
                Self.logger.info("success: report incoming call")
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
        Self.logger.trace("report call ended")

        guard isEnabled else {
            Self.logger.warning("fail: report incoming call: CallKit not enabled")
            return
        }

        let associatedCalls = callRegister.allCalls.filter {
            $0.handle == conversation.callHandle
        }

        for call in associatedCalls {
            Self.logger.info("terminating call: \(String(describing: call))")
            callRegister.unregisterCall(call)
            log("provider.reportCallEndedAt: \(String(describing: timestamp))")
            provider.reportCall(with: call.id, endedAt: timestamp?.clampForCallKit() ?? Date(), reason: reason)
        }
    }

}

// MARK: - Provider delegate

extension CallKitManager: CXProviderDelegate {

    public func providerDidBegin(_ provider: CXProvider) {
        Self.logger.trace("provider did begin")
        log("providerDidBegin: \(provider)")
    }

    public func providerDidReset(_ provider: CXProvider) {
        Self.logger.trace("provider did reset")
        log("providerDidReset: \(provider)")
        mediaManager?.resetAudioDevice()
        callRegister.reset()
        delegate?.endAllCalls()
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Self.logger.trace("perform start call action")
        log("perform CXStartCallAction: \(action)")

        guard let call = callRegister.lookupCall(by: action.callUUID) else {
            Self.logger.warning("fail: perform start call action: call doesn't exist")
            log("fail CXStartCallAction because call did not exist")
            action.fail()
            return
        }

        guard let delegate = delegate else {
            Self.logger.warning("fail: perform start call action: delegate doesn't exist")
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
                    Self.logger.info("success: perform start call action")
                    action.fulfill()
                } else {
                    Self.logger.error("fail: perform start call action: couldn't join call")
                    action.fail()
                }

                let update = CXCallUpdate()
                update.remoteHandle = call.handle.cxHandle
                update.localizedCallerName = conversation.localizedCallerNameForOutgoingCall()
                provider.reportCall(with: action.callUUID, updated: update)

            case .failure(let error):
                Self.logger.error("fail: perform start call action: can't fetch conversation: \(error)")
                self.log("fail CXStartCallAction because can't fetch conversation: \(error)")
                action.fail()
            }
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Self.logger.trace("perform answer call action")
        log("perform CXAnswerCallAction: \(action)")

        guard let call = callRegister.lookupCall(by: action.callUUID) else {
            Self.logger.warning("fail: perform answer call action: call doesn't exist")
            log("fail CXAnswerCallAction because call did not exist")
            action.fail()
            return
        }

        guard let delegate = delegate else {
            Self.logger.warning("fail: perform answer call action: delegate doesn't exist")
            log("fail CXAnswerCallAction because can't fetch conversation")
            action.fail()
            return
        }

        delegate.lookupConversationAndSync(by: call.handle) { [weak self] result in
            guard let `self` = self else {
                action.fail()
                return
            }

            switch result {
            case .success(let conversation):
                call.observer.startObservingChanges(in: conversation)

                call.observer.onEstablished = { [weak self] in
                    Self.logger.info("success: perform answer call action")

                    // Users join conferences in a muted state, so we want to make sure
                    // that the CallKit mute state is in sync with the voice channel mute state.
                    if let voiceChannel = conversation.voiceChannel {
                        self?.requestMuteCall(in: conversation, muted: voiceChannel.muted)
                    }

                    action.fulfill()
                }

                call.observer.onFailedToJoin = {
                    Self.logger.error("fail: perform answer call action: failed to join")
                    action.fail()
                }

                call.observer.onTerminated = { [weak self] reason in
                    self?.reportCallEnded(
                        in: conversation,
                        atTime: nil,
                        reason: reason.CXCallEndedReason
                    )
                }

                Self.logger.info("joining the call...")
                self.mediaManager?.setupAudioDevice()

                if conversation.voiceChannel?.join(video: false) != true {
                    Self.logger.error("fail: perform answer call action: couldn't join call")
                    action.fail()
                }

            case .failure(let error):
                Self.logger.error("fail: perform answer call action: couldn't fetch conversation: \(error)")
                self.log("fail CXAnswerCallAction because can't fetch conversation: \(error)")
                action.fail()
            }
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Self.logger.trace("perform end call action")
        log("perform CXEndCallAction: \(action)")

        guard let call = callRegister.lookupCall(by: action.callUUID) else {
            Self.logger.warning("fail: perform end call action: call doesn't exist")
            log("fail CXEndCallAction because call did not exist")
            action.fail()
            return
        }

        callRegister.unregisterCall(call)

        guard let delegate = delegate else {
            Self.logger.warning("fail: perform end call action: delegate doesn't exist")
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
                Self.logger.info("success: perform end call action")

            case .failure(let error):
                Self.logger.error("fail: perform end call action: couldn't fetch conversation: \(error)")
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
        Self.logger.trace("provider did activate audio session")
        log("didActivate audioSession")
        mediaManager?.startAudio()
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Self.logger.trace("provider did deactivate audio session")
        log("didDeactivate audioSession")
        mediaManager?.resetAudioDevice()
    }

}

// MARK: - Callstate observer

extension CallKitManager: WireCallCenterCallStateObserver, WireCallCenterMissedCallObserver {

    private var shouldHandleCallStates: Bool {
        switch (requirePushTokenType, application.applicationState) {
        case (.standard, .background):
            // Processing call states in the background wiLl interfere with
            // CallKit calls triggered from the NSE.
            return false

        default:
            return true
        }
    }

    public func callCenterDidChange(
        callState: CallState,
        conversation: ZMConversation,
        caller: UserType,
        timestamp: Date?,
        previousCallState: CallState?
    ) {
        Self.logger.trace("received new call state: \(callState)")

        guard shouldHandleCallStates else {
            Self.logger.info("not handling call state: app state is \(String(describing: application.applicationState))")
            return
        }

        switch callState {
        case .incoming(let hasVideo, let shouldRing, degraded: _):
            if shouldRing {
                Self.logger.info("should report an incoming call")

                guard
                    let caller = caller as? ZMUser,
                    conversation.mutedMessageTypesIncludingAvailability == .none,
                    !conversation.needsToBeUpdatedFromBackend
                else {
                    Self.logger.info("will not report incoming call, criteria not met")
                    return
                }

                reportIncomingCall(
                    from: caller,
                    in: conversation,
                    hasVideo: hasVideo
                )

            } else {
                Self.logger.info("will report call ended, reason unanswered")

                reportCallEnded(
                    in: conversation,
                    atTime: timestamp,
                    reason: .unanswered
                )
            }

        case .terminating(let reason):
            Self.logger.info("will report call ended, reason: \(reason)")
            reportCallEnded(
                in: conversation,
                atTime: timestamp,
                reason: reason.CXCallEndedReason
            )

        default:
            break
        }
    }

    public func callCenterMissedCall(
        conversation: ZMConversation,
        caller: UserType,
        timestamp: Date,
        video: Bool
    ) {
        guard isEnabled else { return }

        // Since we missed the call we will not have an assigned callUUID and can just create a random one
        provider.reportCall(
            with: UUID(),
            endedAt: timestamp,
            reason: .unanswered
        )
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

extension CallKitCallRegister {

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
