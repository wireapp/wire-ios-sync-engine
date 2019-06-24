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

@objc
public class LegalHoldRequestStrategy: AbstractRequestStrategy {
    
    fileprivate let syncStatus: SyncStatus
    fileprivate var singleRequstSync: ZMSingleRequestSync!
    
    @objc
    public init(withManagedObjectContext managedObjectContext: NSManagedObjectContext, applicationStatus: ApplicationStatus, syncStatus: SyncStatus) {
        self.syncStatus = syncStatus
        
        super.init(withManagedObjectContext: managedObjectContext, applicationStatus: applicationStatus)
        
        configuration = [.allowsRequestsDuringSync]
        singleRequstSync = ZMSingleRequestSync(singleRequestTranscoder: self, groupQueue: managedObjectContext)
    }
    
    public override func nextRequestIfAllowed() -> ZMTransportRequest? {
        guard syncStatus.currentSyncPhase == .fetchingLegalHoldStatus else { return nil }
        
        singleRequstSync.readyForNextRequestIfNotBusy()
        
        return singleRequstSync.nextRequest()
    }
    
}

extension LegalHoldRequestStrategy: ZMSingleRequestTranscoder {
        
    public func request(for sync: ZMSingleRequestSync) -> ZMTransportRequest? {
        let selfUser = ZMUser.selfUser(in: managedObjectContext)
        
        guard let teamID = selfUser.team?.remoteIdentifier else {
                // Skip sync phase if the user doesn't belong to a team
                syncStatus.finishCurrentSyncPhase(phase: .fetchingLegalHoldStatus)
                return nil
        }
        
        guard let userID = selfUser.remoteIdentifier else { return nil }
        
        return ZMTransportRequest(getFromPath: "teams/\(teamID.transportString())/legalhold/\(userID.transportString())")
    }
    
    public func didReceive(_ response: ZMTransportResponse, forSingleRequest sync: ZMSingleRequestSync) {
        guard response.result == .permanentError || response.result == .success else { return }
        
        if response.result == .success, let payload = response.payload as? [AnyHashable: Any] {
            switch payload["status"] as? String {
            case "pending":
                insertLegalHoldRequest(from: payload)
            case "disabled":
                deleteLegalHoldRequest()
            default:
                break
            }
        }
        
        syncStatus.finishCurrentSyncPhase(phase: .fetchingLegalHoldStatus)
        singleRequstSync.readyForNextRequestIfNotBusy()
    }
    
    func deleteLegalHoldRequest() {
        let selfUser = ZMUser.selfUser(in: managedObjectContext)
        selfUser.legalHoldRequestWasCancelled()
    }
    
    func insertLegalHoldRequest(from payload: [AnyHashable: Any]) {
        let selfUser = ZMUser.selfUser(in: managedObjectContext)
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .base64
        
        do {
            let jsonPayload = try JSONSerialization.data(withJSONObject: payload, options: [])
            let request = try decoder.decode(LegalHoldRequest.self, from: jsonPayload)
            selfUser.userDidReceiveLegalHoldRequest(request)
        } catch {
            Logging.eventProcessing.error("Invalid legal hold request payload: \(error)")
        }
    }
    
}

extension LegalHoldRequestStrategy: ZMEventConsumer {
    
    public func processEvents(_ events: [ZMUpdateEvent], liveEvents: Bool, prefetchResult: ZMFetchRequestBatchResult?) {
        events.forEach(processUpdateEvent)
    }
    
    fileprivate func processUpdateEvent(_ event: ZMUpdateEvent) {
        switch event.type {
        case .userClientLegalHoldRequest:
            processLegalHoldRequestEvent(event)
        default:
            break
        }
    }
    
    fileprivate func processLegalHoldRequestEvent(_ event: ZMUpdateEvent) {
        insertLegalHoldRequest(from: event.payload)
    }
    
}
