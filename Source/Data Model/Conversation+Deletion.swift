//
// Wire
// Copyright (C) 2019 Wire Swiss GmbH
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

public enum ConversationDeletionError: Error {
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

extension ZMConversation {
    
    /// Delete a conversation remotely and locally for everyone
    ///
    /// Only team conversations can be deleted.
    public func delete(in userSession: ZMUserSession, completion: @escaping (VoidResult) -> Void) {
        
        guard conversationType == .group,
              let conversationId = remoteIdentifier,
              let request = ConversationDeletionRequestFactory.requestForDeletingTeamConversation(self)
        else {
            return completion(.failure(ConversationDeletionError.invalidOperation))
        }
        
        request.add(ZMCompletionHandler(on: managedObjectContext!) { response in
            if response.httpStatus == 200 {
                
                userSession.syncManagedObjectContext.performGroupedBlock {
                    guard let conversation = ZMConversation(remoteID: conversationId, createIfNeeded: false, in: userSession.syncManagedObjectContext) else { return }
                    userSession.syncManagedObjectContext.delete(conversation)
                    userSession.syncManagedObjectContext.saveOrRollback()
                }
                
                completion(.success)
            } else {
                let error = ConversationDeletionError(response: response) ?? .unknown
                Logging.network.debug("Error deleting converation: \(error)")
                completion(.failure(error))
            }
        })
        
        userSession.transportSession.enqueueOneTime(request)
        
    }
    
}

struct ConversationDeletionRequestFactory {
    
    static func requestForDeletingTeamConversation(_ conversation: ZMConversation) -> ZMTransportRequest? {
        guard let conversationId = conversation.remoteIdentifier, let teamRemoteIdentifier = conversation.teamRemoteIdentifier else { return nil }
        
        let path = "/teams/\(teamRemoteIdentifier.transportString())/conversations/\(conversationId.transportString())"
        
        return ZMTransportRequest(path: path, method: .methodDELETE, payload: nil)
    }
    
}
