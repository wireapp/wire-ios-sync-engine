//
// Wire
// Copyright (C) 2018 Wire Swiss GmbH
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
 
 private let zmLog = ZMSLog(tag: "Conversation")
 
 public enum ConversationRemoveParticipantError: Error {
    case unknown, invalidOperation, conversationNotFound
    
    init?(response: ZMTransportResponse) {
        switch (response.httpStatus, response.payloadLabel()) {
        case (403, "invalid-op"?): self = .invalidOperation
        case (404, "no-conversation"?): self = .conversationNotFound
        case (400..<499, _): self = .unknown
        default: return nil
        }
    }
 }
 
 public enum ConversationAddParticipantsError: Error {
    case unknown, invalidOperation, accessDenied, notConnectedToUser, conversationNotFound, tooManyMembers, missingLegalHoldConsent
    
    init?(response: ZMTransportResponse) {
        switch (response.httpStatus, response.payloadLabel()) {
        case (403, "invalid-op"?): self = .invalidOperation
        case (403, "access-denied"?): self = .accessDenied
        case (403, "not-connected"?): self = .notConnectedToUser
        case (404, "no-conversation"?): self = .conversationNotFound
        case (403, "too-many-members"?): self = .tooManyMembers
        case (412, "missing-legalhold-consent"?): self = .missingLegalHoldConsent
        case (400..<499, _): self = .unknown
        default: return nil
        }
    }
 }

extension ZMConversation {
    
    public func addParticipants(_ participants: [UserType], userSession: ZMUserSession, completion: @escaping (VoidResult) -> Void) {
        addParticipants(participants,
                        transportSession: userSession.transportSession,
                        eventProcessor: userSession.updateEventProcessor!,
                        contextProvider: userSession.coreDataStack,
                        completion: completion)
    }
    
    func addParticipants(_ participants: [UserType],
                         transportSession: TransportSessionType,
                         eventProcessor: UpdateEventProcessor,
                         contextProvider: ContextProvider,
                         completion: @escaping (VoidResult) -> Void) {
        let users = participants.materialize(in: contextProvider.viewContext)
        
        guard
            conversationType == .group,
            !users.isEmpty,
            !users.contains(ZMUser.selfUser(in: contextProvider.viewContext))
        else { return completion(.failure(ConversationAddParticipantsError.invalidOperation)) }
        
        let request = ConversationParticipantRequestFactory.requestForAddingParticipants(Set(users), conversation: self)
        
        request.add(ZMCompletionHandler(on: managedObjectContext!) { [weak contextProvider, weak eventProcessor] response in
            guard let syncMOC = contextProvider?.syncContext, let eventProcessor = eventProcessor else {
                return  completion(.failure(ConversationAddParticipantsError.unknown))
            }
            
            if response.httpStatus == 200 {
                if let payload = response.payload, let event = ZMUpdateEvent(fromEventStreamPayload: payload, uuid: nil) {
                    syncMOC.performGroupedBlock {
                        eventProcessor.storeAndProcessUpdateEvents([event], ignoreBuffer: true)
                    }
                }
                
                completion(.success)
            }
            else if response.httpStatus == 204 {
                completion(.success) // users were already added to the conversation
            }
            else {
                if response.httpStatus == 403 {
                    // Refresh user data since this operation might have failed
                    // due to a team member being removed/deleted from the team.
                    users.filter(\.isTeamMember).forEach({ $0.refreshData() })
                    contextProvider?.viewContext.enqueueDelayedSave()
                }
                
                let error = ConversationAddParticipantsError(response: response) ?? .unknown
                zmLog.debug("Error adding participants: \(error)")
                completion(.failure(error))
            }
        })
        
        transportSession.enqueueOneTime(request)
    }
    
    public func removeParticipant(_ participant: UserType, userSession: ZMUserSession, completion: @escaping (VoidResult) -> Void) {
        removeParticipant(participant,
                          transportSession: userSession.transportSession,
                          eventProcessor: userSession.updateEventProcessor!,
                          contextProvider: userSession.coreDataStack,
                          completion: completion)
    }
    
    func removeParticipant(_ participant: UserType,
                                  transportSession: TransportSessionType,
                                  eventProcessor: UpdateEventProcessor,
                                  contextProvider: ContextProvider,
                                  completion: @escaping (VoidResult) -> Void) {
        
        guard conversationType == .group,
            let conversationId = remoteIdentifier,
            let user = participant as? ZMUser
        else { return completion(.failure(ConversationRemoveParticipantError.invalidOperation)) }
        
        let isRemovingSelfUser = participant.isSelfUser
        let request = ConversationParticipantRequestFactory.requestForRemovingParticipant(user, conversation: self)
        let domain = self.domain
        
        request.add(ZMCompletionHandler(on: managedObjectContext!) { [weak contextProvider, weak eventProcessor] response in
            guard let syncMOC = contextProvider?.syncContext, let eventProcessor = eventProcessor else {
                return  completion(.failure(ConversationRemoveParticipantError.unknown))
            }
            
            if response.httpStatus == 200 {
                if let payload = response.payload, let event = ZMUpdateEvent(fromEventStreamPayload: payload, uuid: nil) {
                    syncMOC.performGroupedBlock {
                        let conversation = ZMConversation.fetch(with: conversationId, domain: domain, in: syncMOC)
                        
                        // Update cleared timestamp if self user left and deleted history
                        if let clearedTimestamp = conversation?.clearedTimeStamp, clearedTimestamp == conversation?.lastServerTimeStamp, isRemovingSelfUser {
                            conversation?.updateCleared(fromPostPayloadEvent: event)
                        }
                        
                        eventProcessor.storeAndProcessUpdateEvents([event], ignoreBuffer: true)
                    }
                }
                
                completion(.success)
            }
            else if response.httpStatus == 204 {
                completion(.success) // user was already not part of conversation
            }
            else {
                let error = ConversationRemoveParticipantError(response: response) ?? .unknown
                zmLog.debug("Error removing participant: \(error)")
                completion(.failure(error))
            }
        })
        
        transportSession.enqueueOneTime(request)
    }
    
}

internal struct ConversationParticipantRequestFactory {
    
    static func requestForRemovingParticipant(_ participant: ZMUser, conversation: ZMConversation) -> ZMTransportRequest {
        
        let participantKind = participant.isServiceUser ? "bots" : "members"
        let path = "/conversations/\(conversation.remoteIdentifier!.transportString())/\(participantKind)/\(participant.remoteIdentifier!.transportString())"
        
        return ZMTransportRequest(path: path, method: .methodDELETE, payload: nil)
    }
    
    static func requestForAddingParticipants(_ participants: Set<ZMUser>, conversation: ZMConversation) -> ZMTransportRequest {
        
        let path = "/conversations/\(conversation.remoteIdentifier!.transportString())/members"
        let payload: [String: Any] = [
            "users": participants.compactMap { $0.remoteIdentifier?.transportString() },
            "conversation_role": ZMConversation.defaultMemberRoleName
        ]
        
        return ZMTransportRequest(path: path, method: .methodPOST, payload: payload as ZMTransportData)
    }
    
}
