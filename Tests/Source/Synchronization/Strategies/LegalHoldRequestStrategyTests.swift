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

import XCTest

class LegalHoldRequestStrategyTests: MessagingTest {
    
    var sut: LegalHoldRequestStrategy!
    var mockSyncStatus: MockSyncStatus!
    var mockSyncStateDelegate: MockSyncStateDelegate!
    var mockApplicationStatus: MockApplicationStatus!

    override func setUp() {
        super.setUp()
        mockSyncStateDelegate = MockSyncStateDelegate()
        mockSyncStatus = MockSyncStatus(managedObjectContext: syncMOC, syncStateDelegate: mockSyncStateDelegate)
        mockApplicationStatus = MockApplicationStatus()
        mockApplicationStatus.mockSynchronizationState = .synchronizing
        sut = LegalHoldRequestStrategy(withManagedObjectContext: syncMOC, applicationStatus: mockApplicationStatus, syncStatus: mockSyncStatus)
        
        syncMOC.performGroupedBlockAndWait {
            let selfUser = ZMUser.selfUser(in: self.syncMOC)
            selfUser.remoteIdentifier = UUID()
        }
    }

    override func tearDown() {
        sut = nil
        mockSyncStatus = nil
        mockApplicationStatus = nil
        mockSyncStateDelegate = nil
        super.tearDown()
    }
    
    static var legalHoldRequest: LegalHoldRequest {
        return LegalHoldRequest(
            clientIdentifier: "eca3c87cfe28be49",
            lastPrekey: LegalHoldRequest.Prekey(
                id: 65535,
                key: Data(base64Encoded: "pQABAQoCoQBYIPEFMBhOtG0dl6gZrh3kgopEK4i62t9sqyqCBckq3IJgA6EAoQBYIC9gPmCdKyqwj9RiAaeSsUI7zPKDZS+CjoN+sfihk/5VBPY=")!
            )
        )
    }
    
    static func payloadForReceivingLegalHoldRequestStatus(request: LegalHoldRequest) -> ZMTransportData {
        return [
            "status": "pending",
            "client_id": request.clientIdentifier,
            "last_prekey": [
                "id": request.lastPrekey.id,
                "key": request.lastPrekey.key.base64EncodedString()
            ]
            ] as ZMTransportData
    }
    
    static func payloadForReceivingLegalHoldRequestEvent(request: LegalHoldRequest) -> ZMTransportData {
        return [
            "type": "user.client-legal-hold-request",
            "client_id": request.clientIdentifier,
            "last_prekey": [
                "id": request.lastPrekey.id,
                "key": request.lastPrekey.key.base64EncodedString()
            ]
            ] as ZMTransportData
    }
    
    // MARK: - Slow Sync

    func testThatItRequestsLegalHoldStatus_DuringSlowSync() {
        syncMOC.performGroupedBlockAndWait {
            // GIVEN
            self.mockSyncStatus.mockPhase = .fetchingLegalHoldStatus
            
            let selfUser = ZMUser.selfUser(in: self.syncMOC)
            let team = Team.insertNewObject(in: self.syncMOC)
            team.remoteIdentifier = .create()
            _ = Member.getOrCreateMember(for: selfUser, in: team, context: self.syncMOC)
            
            // WHEN
            guard let request = self.sut.nextRequest() else { return XCTFail() }
            
            // THEN
            XCTAssertEqual(request.path, "teams/\(team.remoteIdentifier!.transportString())/legalhold/\(selfUser.remoteIdentifier.transportString())")
        }
    }
    
    func testThatItSkipsLegalHoldSyncPhase_IfUserDoesNotBelongToAteam() {
        syncMOC.performGroupedBlockAndWait {
            // GIVEN
            self.mockSyncStatus.mockPhase = .fetchingLegalHoldStatus
            
            // WHEN
            _ = self.sut.nextRequest()
            
            // THEN
            XCTAssertTrue(self.mockSyncStatus.didCallFinishCurrentSyncPhase)
        }
    }
    
    func testThatISkipsLegalHoldSyncPhase_OnPermanentErrors() {
        syncMOC.performGroupedBlockAndWait {
            // GIVEN
            self.mockSyncStatus.mockPhase = .fetchingLegalHoldStatus
            
            // WHEN
            let request = self.sut.nextRequest()
            request?.complete(with: ZMTransportResponse(payload: nil, httpStatus: 500, transportSessionError: nil))
        }
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        syncMOC.performGroupedBlockAndWait {
            XCTAssertTrue(self.mockSyncStatus.didCallFinishCurrentSyncPhase)
        }
    }
    
    func testThatItCreatesALegalHoldRequest_WhenLegalHoldStatusIsPending() {
        let expectedLegalHoldRequest = type(of: self).legalHoldRequest
        
        syncMOC.performGroupedBlockAndWait {
            // GIVEN
            self.mockSyncStatus.mockPhase = .fetchingLegalHoldStatus
            
            let selfUser = ZMUser.selfUser(in: self.syncMOC)
            let team = Team.insertNewObject(in: self.syncMOC)
            team.remoteIdentifier = .create()
            _ = Member.getOrCreateMember(for: selfUser, in: team, context: self.syncMOC)
            
            let payload = type(of: self).payloadForReceivingLegalHoldRequestStatus(request: expectedLegalHoldRequest)
            guard let request = self.sut.nextRequest() else { return XCTFail() }
            request.complete(with: ZMTransportResponse(payload: payload, httpStatus: 200, transportSessionError: nil))
        }
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        syncMOC.performGroupedBlockAndWait {
            let selfUser = ZMUser.selfUser(in: self.syncMOC)
            guard case .pending(let legalHoldRequest) = selfUser.legalHoldStatus else { return XCTFail() }
            XCTAssertEqual(legalHoldRequest.clientIdentifier, expectedLegalHoldRequest.clientIdentifier)
        }
    }
    
    func testThatItCancelsALegalHoldRequest_WhenLegalHoldStatusIsDisabled() {
        syncMOC.performGroupedBlockAndWait {
            // GIVEN
            self.mockSyncStatus.mockPhase = .fetchingLegalHoldStatus
            
            let selfUser = ZMUser.selfUser(in: self.syncMOC)
            
            let team = Team.insertNewObject(in: self.syncMOC)
            team.remoteIdentifier = .create()
            _ = Member.getOrCreateMember(for: selfUser, in: team, context: self.syncMOC)
            
            let legalHoldRequest = type(of: self).legalHoldRequest
            selfUser.userDidReceiveLegalHoldRequest(legalHoldRequest)
            
            let payload: [AnyHashable: Any] = [
                "status": "disabled"
            ]
            guard let request = self.sut.nextRequest() else { return XCTFail() }
            request.complete(with: ZMTransportResponse(payload: payload as ZMTransportData, httpStatus: 200, transportSessionError: nil))
        }
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        syncMOC.performGroupedBlockAndWait {
            let selfUser = ZMUser.selfUser(in: self.syncMOC)
            XCTAssertEqual(selfUser.legalHoldStatus, .disabled)
        }
    }
    
    // MARK: - Event Processing
        
    func testThatItProcessesValidLegalHoldEventPayloads() {
        // GIVEN
        var selfUser: ZMUser! = nil
        
        syncMOC.performGroupedBlock {
            selfUser = ZMUser.selfUser(in: self.syncMOC)
        }
        
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        let legalHoldRequest = type(of: self).legalHoldRequest
        let payload: [String: Any] = [
            "id": "93912B22-736C-4EFC-9922-E7ECAC5020F5",
            "payload": [
                type(of: self).payloadForReceivingLegalHoldRequestEvent(request: legalHoldRequest)
            ],
            "transient" : false
        ]
        
        let events = ZMUpdateEvent.eventsArray(fromPushChannelData: payload as ZMTransportData)
        guard let event = events!.first else {
            XCTFail()
            return
        }
        
        // when
        syncMOC.performGroupedBlockAndWait {
            self.sut.processEvents([event], liveEvents: true, prefetchResult: .none)
            
            // then
            XCTAssertEqual(selfUser.legalHoldStatus, .pending(legalHoldRequest))
        }
    }
    
}
