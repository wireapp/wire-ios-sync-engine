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

private let zmLog = ZMSLog(tag: "calling")

private let identifierSeparator : Character = "+"

private struct CallKitCall {
    let conversation : ZMConversation
    let observer : CallObserver
    
    init(conversation : ZMConversation) {
        self.conversation = conversation
        self.observer = CallObserver(conversation: conversation)
    }
}

@objc
@available(iOS 10.0, *)
public class CallKitDelegate : NSObject {
    
    fileprivate let provider : CXProvider
    fileprivate let callController : CXCallController
    fileprivate unowned let sessionManager : SessionManagerType
    fileprivate weak var mediaManager: AVSMediaManager?
    fileprivate var callStateObserverToken : Any?
    fileprivate var missedCallObserverToken : Any?
    fileprivate var connectedCallConversation : ZMConversation?
    fileprivate var calls : [UUID : CallKitCall]
    
    public convenience init(sessionManager: SessionManagerType, mediaManager: AVSMediaManager?) {
        self.init(provider: CXProvider(configuration: CallKitDelegate.providerConfiguration),
                  callController: CXCallController(queue: DispatchQueue.main),
                  sessionManager: sessionManager,
                  mediaManager: mediaManager)
    }
    
    public init(provider : CXProvider,
         callController: CXCallController,
         sessionManager: SessionManagerType,
         mediaManager: AVSMediaManager?) {
        
        self.provider = provider
        self.callController = callController
        self.sessionManager = sessionManager
        self.mediaManager = mediaManager
        self.calls = [:]
        
        super.init()
        
        provider.setDelegate(self, queue: nil)
                
        callStateObserverToken = WireCallCenterV3.addGlobalCallStateObserver(observer: self)
        missedCallObserverToken = WireCallCenterV3.addGlobalMissedCallObserver(observer: self)
    }
    
    deinit {
        provider.invalidate()
    }
    
    public static var providerConfiguration : CXProviderConfiguration {
        
        let localizedName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Wire"
        let configuration = CXProviderConfiguration(localizedName: localizedName)

        configuration.supportsVideo = true
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.ringtoneSound = ZMCustomSound.notificationRingingSoundName()
        
        if let image = UIImage(named: "logo") {
            configuration.iconTemplateImageData = UIImagePNGRepresentation(image)
        }
        
        return configuration
    }
    
    fileprivate func log(_ message: String, file: String = #file, line: Int = #line) {
        let messageWithLineNumber = String(format: "%@:%ld: %@", URL(fileURLWithPath: file).lastPathComponent, line, message)
        SessionManager.logAVS(message: messageWithLineNumber)
    }

    fileprivate func actionsToEndAllOngoingCalls(exceptIn conversation: ZMConversation) -> [CXAction] {
        return calls
            .lazy
            .filter { $0.value.conversation != conversation }
            .map { CXEndCallAction(call: $0.key) }
    }
    
    internal func callUUID(for conversation: ZMConversation) -> UUID? {
        return calls.first(where: { $0.value.conversation == conversation })?.key
    }

}

@available(iOS 10.0, *)
extension CallKitDelegate {

    func callIdentifiers(from customIdentifier : String) -> (UUID, UUID)? {
        let identifiers = customIdentifier.split(separator: identifierSeparator)
        
        guard identifiers.count == 2,
              let accountIdentifier = identifiers.first,
              let userIdentifier = identifiers.last,
              let accountId = UUID.init(uuidString: String(accountIdentifier)),
              let userId = UUID.init(uuidString: String(userIdentifier)) else { return nil }
        
        return (accountId, userId)
    }
    
    func findConversationAssociated(with contacts: [INPerson], completion: @escaping (ZMConversation) -> Void) {
        
        guard contacts.count == 1,
              let contact = contacts.first,
              let customIdentifier = contact.customIdentifier,
              let (accountId, conversationId) = callIdentifiers(from: customIdentifier),
              let account = sessionManager.accountManager.account(with: accountId)
        else {
            return
        }
        
        sessionManager.withSession(for: account) { (userSession) in
            if let conversation = ZMConversation(remoteID: conversationId, createIfNeeded: false, in: userSession.managedObjectContext) {
                completion(conversation)
            }
        }
    }
    
    public func continueUserActivity(_ userActivity : NSUserActivity) -> Bool {
        guard let interaction = userActivity.interaction
        else { return false }
        
        let intent = interaction.intent
        var contacts : [INPerson]? = nil
        var video = false
        
        if let audioCallIntent = intent as? INStartAudioCallIntent {
            contacts = audioCallIntent.contacts
            video = false
        }
        else if let videoCallIntent = intent as? INStartVideoCallIntent {
            contacts = videoCallIntent.contacts
            video = true
        }
        
        if let contacts = contacts {
            findConversationAssociated(with: contacts) { [weak self] (conversation) in
                self?.requestStartCall(in: conversation, video: video)
            }
            
            return true
        }
        
        return false
    }
}

@available(iOS 10.0, *)
extension CallKitDelegate {
    
    func requestMuteCall(in conversation: ZMConversation, muted:  Bool) {
        guard let existingCallUUID = callUUID(for: conversation) else { return }
        
        let action = CXSetMutedCallAction(call: existingCallUUID, muted: muted)
        
        callController.request(CXTransaction(action: action)) { [weak self] (error) in
            if let error = error {
                self?.log("Cannot update call to muted = \(muted): \(error)")
            }
        }
    }
    
    func requestJoinCall(in conversation: ZMConversation, video: Bool) {
        
        let existingCallUUID = callUUID(for: conversation)
        let existingCall = callController.callObserver.calls.first(where: { $0.uuid == existingCallUUID })
        
        if let call = existingCall, !call.isOutgoing {
            requestAnswerCall(in: conversation, video: video)
        } else {
            requestStartCall(in: conversation, video: video)
        }
    }
    
    func requestStartCall(in conversation: ZMConversation, video: Bool) {
        guard
            let managedObjectContext = conversation.managedObjectContext,
            let handle = conversation.callKitHandle
        else {
            self.log("Ignore request to start call since remoteIdentifier or handle is nil")
            return
        }
        
        let callUUID = UUID()
        calls[callUUID] = CallKitCall(conversation: conversation)
        
        let action = CXStartCallAction(call: callUUID, handle: handle)
        action.isVideo = video
        action.contactIdentifier = conversation.localizedCallerName(with: ZMUser.selfUser(in: managedObjectContext))

        let endCallActions = actionsToEndAllOngoingCalls(exceptIn: conversation)
        let transaction = CXTransaction(actions: endCallActions + [action])
        
        callController.request(transaction) { [weak self] (error) in
            if let error = error as? CXErrorCodeRequestTransactionError, error.code == .callUUIDAlreadyExists {
                self?.requestAnswerCall(in: conversation, video: video)
            } else if let error = error {
                self?.log("Cannot start call: \(error)")
            }
        }
        
    }
    
    func requestAnswerCall(in conversation: ZMConversation, video: Bool) {
        guard let callUUID = callUUID(for: conversation) else { return }
        
        let action = CXAnswerCallAction(call: callUUID)
        let endPreviousActions = actionsToEndAllOngoingCalls(exceptIn: conversation)
        let transaction = CXTransaction(actions: endPreviousActions + [action])
        
        callController.request(transaction) { [weak self] (error) in
            if let error = error {
                self?.log("Cannot answer call: \(error)")
            }
        }
    }
    
    func requestEndCall(in conversation: ZMConversation) {
        guard let callUUID = callUUID(for: conversation) else { return }
        
        let action = CXEndCallAction(call: callUUID)
        let transaction = CXTransaction(action: action)
        
        callController.request(transaction) { [weak self] (error) in
            if let error = error {
                self?.log("Cannot end call: \(error)")
                conversation.voiceChannel?.leave()
            }
        }
    }
    
    func reportIncomingCall(from user: ZMUser, in conversation: ZMConversation, video: Bool) {
        guard let handle = conversation.callKitHandle else {
            return log("Cannot report incoming call: conversation is missing handle")
        }
        
        let update = CXCallUpdate()
        update.supportsHolding = false
        update.supportsDTMF = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.localizedCallerName = conversation.localizedCallerName(with: user)
        update.remoteHandle = handle
        update.hasVideo = video
        
        let callUUID = UUID()
        calls[callUUID] = CallKitCall(conversation: conversation)
        
        provider.reportNewIncomingCall(with: callUUID, update: update) { [weak self] (error) in
            if let error = error {
                self?.log("Cannot report incoming call: \(error)")
                self?.calls.removeValue(forKey: callUUID)
                conversation.voiceChannel?.leave()
            } else {
                self?.mediaManager?.setupAudioDevice()
            }
        }
    }
    
    func reportCall(in conversation: ZMConversation, endedAt timestamp: Date?, reason: CXCallEndedReason) {
        
        var associatedCallUUIDs : [UUID] = []
        for call in calls {
            if call.value.conversation == conversation {
                associatedCallUUIDs.append(call.key)
            }
        }
        
        associatedCallUUIDs.forEach { (callUUID) in
            calls.removeValue(forKey: callUUID)
            provider.reportCall(with: callUUID, endedAt: timestamp, reason: reason)
        }
    }
}

@available(iOS 10.0, *)
extension CallKitDelegate : CXProviderDelegate {
    
    public func providerDidBegin(_ provider: CXProvider) {
        log("providerDidBegin: \(provider)")
    }
    
    public func providerDidReset(_ provider: CXProvider) {
        log("providerDidReset: \(provider)")
        mediaManager?.resetAudioDevice()
        calls.removeAll()
        
        // leave all active calls
        for (_, userSession) in sessionManager.backgroundUserSessions {
            for conversation in userSession.callCenter?.nonIdleCallConversations(in: userSession) ?? [] {
                conversation.voiceChannel?.leave()
            }
        }
    }
    
    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        log("perform CXStartCallAction: \(action)")
        
        guard let call = calls[action.callUUID] else {
            log("fail CXStartCallAction because call did not exist")
            action.fail()
            return
        }
        
        call.observer.onAnswered = {
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        }
        
        call.observer.onEstablished = {
            provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
        }
        
        mediaManager?.setupAudioDevice()
        
        if call.conversation.voiceChannel?.join(video: action.isVideo) == true {
            action.fulfill()
        } else {
            action.fail()
        }
        
        let update = CXCallUpdate()
        update.remoteHandle = call.conversation.callKitHandle
        update.localizedCallerName = call.conversation.localizedCallerNameForOutgoingCall()
        
        provider.reportCall(with: action.callUUID, updated: update)
    }
    
    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        log("perform CXAnswerCallAction: \(action)")
        
        guard let call = calls[action.callUUID] else {
            log("fail CXAnswerCallAction because call did not exist")
            action.fail()
            return
        }
        
        call.observer.onEstablished = {
            action.fulfill()
        }
        
        call.observer.onFailedToJoin = {
            action.fail()
        }
        
        if call.conversation.voiceChannel?.join(video: false) != true {
            action.fail()
        }
    }
    
    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        log("perform CXEndCallAction: \(action)")
        
        guard let call = calls[action.callUUID] else {
            log("fail CXEndCallAction because call did not exist")
            action.fail()
            return
        }
        
        calls.removeValue(forKey: action.callUUID)
        call.conversation.voiceChannel?.leave()
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        log("perform CXSetHeldCallAction: \(action)")
        mediaManager?.isMicrophoneMuted = action.isOnHold
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        log("perform CXSetMutedCallAction: \(action)")
        mediaManager?.isMicrophoneMuted = action.isMuted
        action.fulfill()
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

@available(iOS 10.0, *)
extension CallKitDelegate : WireCallCenterCallStateObserver, WireCallCenterMissedCallObserver {
    
    public func callCenterDidChange(callState: CallState, conversation: ZMConversation, caller: ZMUser, timestamp: Date?, previousCallState: CallState?) {
        
        switch callState {
        case .incoming(video: let video, shouldRing: let shouldRing, degraded: _):
            if shouldRing {
                if !conversation.isSilenced {
                    reportIncomingCall(from: caller, in: conversation, video: video)
                }
            } else {
                reportCall(in: conversation, endedAt: timestamp, reason: .unanswered)
            }
        case let .terminating(reason: reason):
            reportCall(in: conversation, endedAt: timestamp, reason: reason.CXCallEndedReason)
        default:
            break
        }
    }
    
    public func callCenterMissedCall(conversation: ZMConversation, caller: ZMUser, timestamp: Date, video: Bool) {
        // Since we missed the call we will not have an assigned callUUID and can just create a random one
        provider.reportCall(with: UUID(), endedAt: timestamp, reason: .unanswered)
    }
    
}

@available(iOS 10.0, *)
extension ZMConversation {
    
    var callKitHandle: CXHandle? {
        if let managedObjectContext = managedObjectContext,
           let userId = ZMUser.selfUser(in: managedObjectContext).remoteIdentifier,
           let remoteIdentifier = remoteIdentifier {
            return CXHandle(type: .generic, value: userId.transportString() + String(identifierSeparator) + remoteIdentifier.transportString())
        }
        
        return nil
    }
    
    func localizedCallerNameForOutgoingCall() -> String? {
        guard let managedObjectContext = self.managedObjectContext  else { return nil }
        
        return localizedCallerName(with: ZMUser.selfUser(in: managedObjectContext))
    }
    
    func localizedCallerName(with user: ZMUser) -> String {
        
        let conversationName = self.userDefinedName
        let callerName : String? = user.name
        var result : String? = nil
        
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
            result = connectedUser?.displayName
        default:
            break
        }
        
        return result ?? String.localizedStringWithFormat("callkit.call.started.group.nousername.noconversationname".pushFormatString)
    }
    
}

@available(iOS 10.0, *)
extension CXCallAction {
    
    func conversation(in context : NSManagedObjectContext) -> ZMConversation? {
        return ZMConversation(remoteID: callUUID, createIfNeeded: false, in: context)
    }
    
}

extension CallClosedReason {
    
    @available(iOS 10.0, *)
    var CXCallEndedReason : CXCallEndedReason {
        switch self {
        case .timeout:
            return .unanswered
        case .normal, .canceled:
            return .remoteEnded
        case .anweredElsewhere:
            return .answeredElsewhere
        default:
            return .failed
        }
    }
    
}

class CallObserver : WireCallCenterCallStateObserver {
    
    private var token : Any?
    
    public var onAnswered : (() -> Void)?
    public var onEstablished : (() -> Void)?
    public var onFailedToJoin : (() -> Void)?
    
    public init(conversation: ZMConversation) {
        token = WireCallCenterV3.addCallStateObserver(observer: self, for: conversation, context: conversation.managedObjectContext!)
    }
    
    public func callCenterDidChange(callState: CallState, conversation: ZMConversation, caller: ZMUser, timestamp: Date?, previousCallState: CallState?) {
        switch callState {
        case .answered(degraded: false):
            onAnswered?()
        case .establishedDataChannel:
            onEstablished?()
        case .terminating(reason: let reason):
            switch reason {
            case .inputOutputError, .internalError, .unknown, .lostMedia, .anweredElsewhere:
                onFailedToJoin?()
            default:
                break
            }
        default:
            break
        }
    }
    
}
