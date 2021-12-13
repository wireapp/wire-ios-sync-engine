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

private let zmLog = ZMSLog(tag: "ConversationLink")

public enum SetAllowGuestsError: Error {
    case unknown
}

fileprivate extension ZMConversation {
    struct TransportKey {
        static let data = "data"
        static let uri = "uri"
    }
}

public enum WirelessLinkError: Error {
    case noCode
    case invalidOperation
    case unknown

    init?(response: ZMTransportResponse) {
        switch (response.httpStatus, response.payloadLabel()) {
        case (403, "invalid-op"?): self = .invalidOperation
        case (404, "no-conversation-code"?): self = .noCode
        case (400..<499, _): self = .unknown
        default: return nil
        }
    }
}

extension ZMConversation {

    /// Fetches the link to access the conversation.
    /// @param completion called when the operation is ended. Called with .success and the link fetched. If the link
    ///        was not generated yet, it is called with .success(nil).
    public func fetchWirelessLink(in userSession: ZMUserSession, _ completion: @escaping (Result<String?>) -> Void) {
        guard canManageAccess else {
            return completion(.failure(WirelessLinkError.invalidOperation))
        }

        let request = WirelessRequestFactory.fetchLinkRequest(for: self)
        request.add(ZMCompletionHandler(on: managedObjectContext!) { response in
            if response.httpStatus == 200,
                let uri = response.payload?.asDictionary()?[ZMConversation.TransportKey.uri] as? String {
                completion(.success(uri))
            }
            else if response.httpStatus == 404 {
                completion(.success(nil))
            }
            else {
                let error = WirelessLinkError(response: response) ?? .unknown
                zmLog.debug("Error fetching wireless link: \(error)")
                completion(.failure(error))
            }
        })

        userSession.transportSession.enqueueOneTime(request)
    }

    var isLegacyAccessMode: Bool {
        return self.accessMode == [.invite]
    }

    /// Updates the conversation access mode if necessary and creates the link to access the conversation.
    public func updateAccessAndCreateWirelessLink(in userSession: ZMUserSession, _ completion: @escaping (Result<String>) -> Void) {
        // Legacy access mode: access and access_mode have to be updated in order to create the link.
        if isLegacyAccessMode {
            setAllowGuests(true, in: userSession) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success:
                    self.createWirelessLink(in: userSession, completion)
                }
            }
        }
        else {
            createWirelessLink(in: userSession, completion)
        }
    }

    func createWirelessLink(in userSession: ZMUserSession, _ completion: @escaping (Result<String>) -> Void) {
        guard canManageAccess else {
            return completion(.failure(WirelessLinkError.invalidOperation))
        }

        let request = WirelessRequestFactory.createLinkRequest(for: self)
        request.add(ZMCompletionHandler(on: managedObjectContext!) { response in
            if response.httpStatus == 201,
                let payload = response.payload,
                let data = payload.asDictionary()?[ZMConversation.TransportKey.data] as? [String: Any],
                let uri = data[ZMConversation.TransportKey.uri] as? String {

                completion(.success(uri))

                if let event = ZMUpdateEvent(fromEventStreamPayload: payload, uuid: nil) {
                    // Process `conversation.code-update` event
                    userSession.syncManagedObjectContext.performGroupedBlock {
                        userSession.updateEventProcessor?.storeAndProcessUpdateEvents([event], ignoreBuffer: true)
                    }
                }
            }
            else if response.httpStatus == 200,
                let payload = response.payload?.asDictionary(),
                let uri = payload[ZMConversation.TransportKey.uri] as? String {
                completion(.success(uri))
            }
            else {
                let error = WirelessLinkError(response: response) ?? .unknown
                zmLog.error("Error creating wireless link: \(error)")
                completion(.failure(error))
            }
        })

        userSession.transportSession.enqueueOneTime(request)
    }

    /// Deletes the existing wireless link.
    public func deleteWirelessLink(in userSession: ZMUserSession, _ completion: @escaping (VoidResult) -> Void) {
        guard canManageAccess else {
            return completion(.failure(WirelessLinkError.invalidOperation))
        }

        let request = WirelessRequestFactory.deleteLinkRequest(for: self)

        request.add(ZMCompletionHandler(on: managedObjectContext!) { response in
            if response.httpStatus == 200 {
                completion(.success)
            } else {
                let error = WirelessLinkError(response: response) ?? .unknown
                zmLog.debug("Error creating wireless link: \(error)")
                completion(.failure(error))
            }
        })

        userSession.transportSession.enqueueOneTime(request)
    }

    /// Changes the conversation access mode to allow guests.
    public func setAllowGuests(_ allowGuests: Bool, in userSession: ZMUserSession, _ completion: @escaping (VoidResult) -> Void) {
        guard canManageAccess else {
            return completion(.failure(WirelessLinkError.invalidOperation))
        }

        let request = WirelessRequestFactory.set(allowGuests: allowGuests, for: self)
        request.add(ZMCompletionHandler(on: managedObjectContext!) { response in
            if let payload = response.payload,
                let event = ZMUpdateEvent(fromEventStreamPayload: payload, uuid: nil) {
                self.allowGuests = allowGuests
                // Process `conversation.access-update` event
                userSession.syncManagedObjectContext.performGroupedBlock {
                    userSession.updateEventProcessor?.storeAndProcessUpdateEvents([event], ignoreBuffer: true)
                }
                completion(.success)
            } else {
                zmLog.debug("Error creating wireless link: \(response)")
                completion(.failure(SetAllowGuestsError.unknown))
            }
        })

        userSession.transportSession.enqueueOneTime(request)
    }

    public var canManageAccess: Bool {
        guard let moc = self.managedObjectContext else { return false }
        let selfUser = ZMUser.selfUser(in: moc)
        return selfUser.canModifyAccessControlSettings(in: self)
    }
}

internal struct WirelessRequestFactory {
    static func fetchLinkRequest(for conversation: ZMConversation) -> ZMTransportRequest {
        guard let identifier = conversation.remoteIdentifier?.transportString() else {
            fatal("conversation is not yet inserted on the backend")
        }
        return .init(getFromPath: "/conversations/\(identifier)/code")
    }

    static func createLinkRequest(for conversation: ZMConversation) -> ZMTransportRequest {
        guard let identifier = conversation.remoteIdentifier?.transportString() else {
            fatal("conversation is not yet inserted on the backend")
        }
        return .init(path: "/conversations/\(identifier)/code", method: .methodPOST, payload: nil)
    }

    static func deleteLinkRequest(for conversation: ZMConversation) -> ZMTransportRequest {
        guard let identifier = conversation.remoteIdentifier?.transportString() else {
            fatal("conversation is not yet inserted on the backend")
        }
        return .init(path: "/conversations/\(identifier)/code", method: .methodDELETE, payload: nil)
    }

    static func set(allowGuests: Bool, for conversation: ZMConversation) -> ZMTransportRequest {
        guard let identifier = conversation.remoteIdentifier?.transportString() else {
            fatal("conversation is not yet inserted on the backend")
        }
        let payload = [ "access": ConversationAccessMode.value(forAllowGuests: allowGuests).stringValue as Any,
                        "access_role": ConversationAccessRole.value(forAllowGuests: allowGuests).rawValue]
        return .init(path: "/conversations/\(identifier)/access", method: .methodPUT, payload: payload as ZMTransportData)
    }
}
