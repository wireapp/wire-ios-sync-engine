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

//import Foundation
//
//private enum RequestError: Int, Error {
//    case unknown = 0
//}
//
//extension ZMConversation {
//
//    private typealias Factory = ConversationRoleRequestFactory
//
//    public func updateRole(of participant: UserType,
//                           to newRole: Role,
//                           session: ZMUserSession,
//                           completion: @escaping (VoidResult) -> Void) {
//
//        guard let user = participant as? ZMUser else {
//            completion(.failure(RequestError.unknown))
//            return
//        }
//        let maybeRequest = Factory.requestForUpdatingParticipantRole(newRole,
//                                                                     for: user,
//                                                                     in: self,
//                                                                     completion: completion)
//        if let request = maybeRequest {
//            session.transportSession.enqueueOneTime(request)
//        }
//    }
//}
//
//struct ConversationRoleRequestFactory {
//
//    static func requestForUpdatingParticipantRole(_ role: Role,
//                                                  for participant: ZMUser,
//                                                  in conversation: ZMConversation,
//                                                  completion: ((VoidResult) -> Void)? = nil) -> ZMTransportRequest? {
//        guard
//            let roleName = role.name,
//            let userId = participant.remoteIdentifier,
//            let conversationId = conversation.remoteIdentifier
//        else {
//            completion?(.failure(RequestError.unknown))
//            return nil
//        }
//
//        let path = "/conversations/\(conversationId.transportString())/members/\(userId.transportString())"
//        let payload = ["conversation_role": roleName]
//
//        let requestCompletionHandler = ZMCompletionHandler(on: conversation.managedObjectContext!) { response in
//            switch response.httpStatus {
//            case 200..<300:
//                conversation.addParticipantAndUpdateConversationState(user: participant, role: role)
//                conversation.managedObjectContext?.saveOrRollback()
//                completion?(.success)
//            default:
//                completion?(.failure(RequestError.unknown))
//            }
//        }
//
//        let request = ZMTransportRequest(path: path, method: .methodPUT, payload: payload as ZMTransportData)
//        request.add(requestCompletionHandler)
//
//        return request
//    }
//}
