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

fileprivate extension ZMConversation {
    
    static var predicateForObjectsNeedingToDownloadRoles: NSPredicate = {
        NSPredicate(format: "%K == YES AND %K != NULL", #keyPath(ZMConversation.needsToDownloadRoles), ZMConversation.remoteIdentifierDataKey()!)
    }()
    
    func updateRoles(with response: ZMTransportResponse) {
        guard let rolesPayload = response.payload?.asDictionary()?["conversation_roles"] as? [[String: Any]] else { return }
        let existingRoles = nonTeamRoles

        // Update or insert new roles
        let newRoles = rolesPayload.compactMap {
            Role.createOrUpdate(with: $0, teamOrConversation: .conversation(self), context: managedObjectContext!)
        }
        
        // Delete removed roles
        let rolesToDelete = existingRoles.subtracting(newRoles)
        rolesToDelete.forEach {
            managedObjectContext?.delete($0)
        }
    }

}

@objc
public final class ConversationRoleDownstreamRequestStrategy: AbstractRequestStrategy, ZMContextChangeTrackerSource, ZMRequestGeneratorSource {
    fileprivate let jsonDecoder = JSONDecoder()
    private (set) var downstreamSync: ZMDownstreamObjectSync!

    @objc
    public override init(withManagedObjectContext managedObjectContext: NSManagedObjectContext, applicationStatus: ApplicationStatus) {
        
        super.init(withManagedObjectContext: managedObjectContext,
                   applicationStatus: applicationStatus)
        
        configuration = [.allowsRequestsDuringEventProcessing]
        
        downstreamSync = ZMDownstreamObjectSync(
            transcoder: self,
            entityName: ZMConversation.entityName(),
            predicateForObjectsToDownload: ZMConversation.predicateForObjectsNeedingToDownloadRoles,
            filter: nil,
            managedObjectContext: managedObjectContext
        )

    }
    
    public override func nextRequestIfAllowed() -> ZMTransportRequest? {
        return downstreamSync.nextRequest()
    }
    
    public var contextChangeTrackers: [ZMContextChangeTracker] {
        return [downstreamSync]
    }
    
    public var requestGenerators: [ZMRequestGenerator] {
        return [downstreamSync]
    }
}


extension ConversationRoleDownstreamRequestStrategy: ZMDownstreamTranscoder {
    static let requestPath = "/conversations"

    public static func getRolesRequest(in conversationIdentifier: UUID) -> ZMTransportRequest {
        let path = requestPath + "/" + conversationIdentifier.transportString() + "/roles"
        return ZMTransportRequest(getFromPath: path)
    }

    public func request(forFetching object: ZMManagedObject!, downstreamSync: ZMObjectSync!) -> ZMTransportRequest! {
        guard downstreamSync as? ZMDownstreamObjectSync == self.downstreamSync,
              let conversation = object as? ZMConversation else { fatal("Wrong sync or object for: \(object.safeForLoggingDescription)") }
        return conversation.remoteIdentifier.map(ConversationRoleDownstreamRequestStrategy.getRolesRequest)
    }
    
    public func delete(_ object: ZMManagedObject!, with response: ZMTransportResponse!, downstreamSync: ZMObjectSync!) {
        // do not delete conversation
    }
    
    public func update(_ object: ZMManagedObject!, with response: ZMTransportResponse!, downstreamSync: ZMObjectSync!) {
        guard downstreamSync as? ZMDownstreamObjectSync == self.downstreamSync,
              let conversation = object as? ZMConversation else { return }
        
        conversation.needsToDownloadRoles = false
        conversation.updateRoles(with: response)
    }
    
}
