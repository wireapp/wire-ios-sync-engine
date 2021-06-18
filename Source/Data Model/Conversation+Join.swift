//
// Wire
// Copyright (C) 2021 Wire Swiss GmbH
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

public enum ConversationJoinError: Error {
    case unknown, tooManyMembers, invalidCode, noConversation

    init(response: ZMTransportResponse) {
        switch (response.httpStatus, response.payloadLabel()) {
        case (403, "too-many-members"?): self = .tooManyMembers
        case (404, "no-conversation-code"?): self = .invalidCode
        case (404, "no-conversation"?): self = .noConversation
        default: self = .unknown
        }
    }
}

public enum ConversationFetchError: Error {
    case unknown, noTeamMember, accessDenied, invalidCode, noConversation

    init(response: ZMTransportResponse) {
        switch (response.httpStatus, response.payloadLabel()) {
        case (403, "no-team-member"?): self = .noTeamMember
        case (403, "access-denied"?): self = .accessDenied
        case (404, "no-conversation-code"?): self = .invalidCode
        case (404, "no-conversation"?): self = .noConversation
        default: self = .unknown
        }
    }
}

extension ZMConversation {

    /// Join a conversation using a reusable code
    /// - Parameters:
    ///   - key: stable conversation identifier
    ///   - code: conversation code
    ///   - transportSession: session to handle requests
    ///   - eventProcessor: update event processor
    ///   - contextProvider: context provider
    ///   - completion: called when the user joines the conversation or when it fails. If the completion is a success, it is run in the main thread
    public static func join(key: String,
                            code: String,
                            transportSession: TransportSessionType,
                            eventProcessor: UpdateEventProcessor,
                            contextProvider: ContextProvider,
                            completion: @escaping (Result<ZMConversation>) -> Void) {

        let request = ConversationJoinRequestFactory.requestForJoinConversation(key: key, code: code)
        let syncContext = contextProvider.syncContext
        let viewContext = contextProvider.viewContext

        request.add(ZMCompletionHandler(on: syncContext, block: { response in
            switch response.httpStatus {
            case 200:
                guard let payload = response.payload,
                      let event = ZMUpdateEvent(fromEventStreamPayload: payload, uuid: nil),
                      let conversationString = event.payload["conversation"] as? String else {
                    return completion(.failure(ConversationJoinError.unknown))
                }

                syncContext.performGroupedBlock {
                    eventProcessor.storeAndProcessUpdateEvents([event], ignoreBuffer: true)

                    viewContext.performGroupedBlock {
                        guard let conversationId = UUID(uuidString: conversationString),
                              let conversation = ZMConversation(remoteID: conversationId, createIfNeeded: false, in: viewContext) else {
                            return completion(.failure(ConversationJoinError.unknown))
                        }

                        completion(.success(conversation))
                    }
                }

            /// The user is already a participant in the conversation
            case 204:
                /// If we came to this case it mean we need to re-sync local conversations
                Logging.network.debug("Local conversations should be re-synced with remote ones")
                return completion(.failure(ConversationJoinError.unknown))

            default:
                let error = ConversationJoinError(response: response)
                Logging.network.debug("Error joining conversation using a reusable code: \(error)")
                completion(.failure(error))
            }
        }))
        transportSession.enqueueOneTime(request)
    }

    /// Fetch conversation ID and name using a reusable code
    /// - Parameters:
    ///   - key: stable conversation identifier
    ///   - code: conversation code
    ///   - transportSession: session to handle requests
    ///   - eventProcessor: update event processor
    ///   - contextProvider: context provider
    ///   - completion: a handler when the network request completes with the response payload that contains the conversation ID and name
    static func fetchIdAndName(key: String,
                               code: String,
                               transportSession: TransportSessionType,
                               eventProcessor: UpdateEventProcessor,
                               contextProvider: ContextProvider,
                               completion: @escaping (Result<(conversationId: UUID, conversationName: String)>) -> Void) {

        let request = ConversationJoinRequestFactory.requestForGetConversation(key: key, code: code)
        let viewContext = contextProvider.viewContext

        request.add(ZMCompletionHandler(on: viewContext, block: { response in
            switch response.httpStatus {
            case 200:
                guard let payload = response.payload as? [AnyHashable : Any],
                      let conversationString = payload["id"] as? String,
                      let conversationId = UUID(uuidString: conversationString),
                      let conversationName = payload["name"] as? String else {
                    completion(.failure(ConversationFetchError.unknown))
                    return
                }
                let fetchResult = (conversationId, conversationName)
                completion(.success(fetchResult))
            default:
                let error = ConversationFetchError(response: response)
                Logging.network.debug("Error fetching conversation ID and name using a reusable code: \(error)")
                completion(.failure(error))
            }
        }))

        transportSession.enqueueOneTime(request)
    }

}

internal struct ConversationJoinRequestFactory {

    static func requestForJoinConversation(key: String, code: String) -> ZMTransportRequest {
        let path = "/conversations/join"
        let payload: [String: Any] = [
            "key": key,
            "code": code
        ]

        return ZMTransportRequest(path: path, method: .methodPOST, payload: payload as ZMTransportData)
    }

    static func requestForGetConversation(key: String, code: String) -> ZMTransportRequest {
        var url = URLComponents()
        url.path = "/conversations/join"
        url.queryItems = [URLQueryItem(name: "key", value: key), URLQueryItem(name: "code", value: code)]
        let urlString = url.string ?? ""

        return ZMTransportRequest(path: urlString, method: .methodGET, payload: nil)
    }

}
