
//
// Wire
// Copyright (C) 2017 Wire Swiss GmbH
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


fileprivate extension Team {
    
    static var predicateForTeamRolesNeedingToBeUpdated: NSPredicate = {
        NSPredicate(format: "%K == YES AND %K != NULL", #keyPath(Team.needsToDownloadRoles), Team.remoteIdentifierDataKey()!)
    }()
    
    func updateRoles(with payload: [String: Any]) {
        guard let rolesPayload = payload["conversation_roles"] as? [[String: Any]] else { return }
        let existingRoles = self.roles
        
        // Update or insert new roles
        let newRoles = rolesPayload.compactMap {
            Role.createOrUpdate(with: $0, teamOrConversation: .team(self), context: managedObjectContext!)
        }
        
        // Delete removed roles
        let rolesToDelete = existingRoles.subtracting(newRoles)
        rolesToDelete.forEach {
            managedObjectContext?.delete($0)
        }
    }
    
}

@objc
public final class TeamRolesDownloadRequestStrategy: AbstractRequestStrategy, ZMContextChangeTrackerSource, ZMRequestGeneratorSource, ZMRequestGenerator {
    
    private (set) var downstreamSync: ZMDownstreamObjectSync!
    fileprivate unowned var syncStatus: SyncStatus
    
    public init(withManagedObjectContext managedObjectContext: NSManagedObjectContext, applicationStatus: ApplicationStatus, syncStatus: SyncStatus) {
        self.syncStatus = syncStatus
        super.init(withManagedObjectContext: managedObjectContext, applicationStatus: applicationStatus)
        downstreamSync = ZMDownstreamObjectSync(
            transcoder: self,
            entityName: Team.entityName(),
            predicateForObjectsToDownload: Team.predicateForTeamRolesNeedingToBeUpdated,
            filter: nil,
            managedObjectContext: managedObjectContext
        )
    }
    
    public override func nextRequest() -> ZMTransportRequest? {
        let request = downstreamSync.nextRequest()
        if request == nil {
            completeSyncPhaseIfNoTeam()
        }
        return request
    }
    
    public var contextChangeTrackers: [ZMContextChangeTracker] {
        return [downstreamSync]
    }
    
    public var requestGenerators: [ZMRequestGenerator] {
        return [self]
    }
    
    fileprivate let expectedSyncPhase = SyncPhase.fetchingTeamRoles
    
    fileprivate var isSyncing: Bool {
        return syncStatus.currentSyncPhase == self.expectedSyncPhase
    }
    
    private func completeSyncPhaseIfNoTeam() {///TODO: crash here, OCMockObject(WireSyncEngine.SyncStatus) has no currentSyncPhase?
        if self.syncStatus.currentSyncPhase == self.expectedSyncPhase && !self.downstreamSync.hasOutstandingItems {
            self.syncStatus.finishCurrentSyncPhase(phase: self.expectedSyncPhase)
        }
    }
}


extension TeamRolesDownloadRequestStrategy: ZMDownstreamTranscoder {
    
    public func request(forFetching object: ZMManagedObject!, downstreamSync: ZMObjectSync!) -> ZMTransportRequest! {
        guard downstreamSync as? ZMDownstreamObjectSync == self.downstreamSync, let team = object as? Team else { fatal("Wrong sync or object for: \(object.safeForLoggingDescription)") }
        return TeamDownloadRequestFactory.requestToDownloadRoles(for: team.remoteIdentifier!)
    }
    
    public func update(_ object: ZMManagedObject!, with response: ZMTransportResponse!, downstreamSync: ZMObjectSync!) {
        guard downstreamSync as? ZMDownstreamObjectSync == self.downstreamSync,
            let team = object as? Team,
            let payload = response.payload?.asDictionary() as? [String: Any] else { return }
        
        
        team.needsToDownloadRoles = false
        team.updateRoles(with: payload)
        
        if self.isSyncing {
            self.syncStatus.finishCurrentSyncPhase(phase: self.expectedSyncPhase)
        }
    }
    
    public func delete(_ object: ZMManagedObject!, with response: ZMTransportResponse!, downstreamSync: ZMObjectSync!) {
        // pass
    }
}