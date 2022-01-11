//
// Wire
// Copyright (C) 2020 Wire Swiss GmbH
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

import Foundation
@testable import WireSyncEngine

class FeatureFlagRequestStrategyTests: MessagingTest {

    var sut: FeatureFlagRequestStrategy!
    var mockSyncStatus: MockSyncStatus!
    var mockSyncStateDelegate: MockSyncStateDelegate!
    var mockApplicationStatus: MockApplicationStatus!

    var selfUser: ZMUser!
    var team: Team!

    override func setUp() {
        super.setUp()
        mockSyncStateDelegate = MockSyncStateDelegate()
        mockSyncStatus = MockSyncStatus(managedObjectContext: syncMOC, syncStateDelegate: mockSyncStateDelegate)
        mockApplicationStatus = MockApplicationStatus()
        mockApplicationStatus.mockSynchronizationState = .slowSyncing

        sut = FeatureFlagRequestStrategy(withManagedObjectContext: syncMOC,
                                         applicationStatus: mockApplicationStatus,
                                         syncStatus: mockSyncStatus)

        team = Team.insertNewObject(in: self.syncMOC)
        team.name = "Wire Amazing Team"
        team.remoteIdentifier = UUID.create()
        selfUser = ZMUser.selfUser(in: self.syncMOC)
        selfUser.teamIdentifier = team.remoteIdentifier
        uiMOC.saveOrRollback()

        syncMOC.performGroupedBlockAndWait {
            FeatureFlag.insert(with: .digitalSignature,
                               value: false,
                               team: self.team,
                               context: self.syncMOC)
        }
    }

    override func tearDown() {
        sut = nil
        mockSyncStatus = nil
        mockApplicationStatus = nil
        mockSyncStateDelegate = nil
        selfUser = nil
        team = nil
        super.tearDown()
    }

    // MARK: - Slow Sync

    func testThatItRequestsFeatureFlags_DuringSlowSync() {
        syncMOC.performGroupedBlockAndWait {
            // GIVEN
            self.mockSyncStatus.mockPhase = .fetchingFeatureFlags

            // WHEN
            guard
                let teamId = self.selfUser.teamIdentifier?.uuidString,
                let request = self.sut.nextRequest()
            else {
                return XCTFail()
            }

            // THEN
            XCTAssertEqual(request.path, "/teams/\(teamId)/features/digital-signatures")
        }
    }

    func testThatItFinishSlowSyncPhase_WhenFeatureFlagsExist() {
        syncMOC.performGroupedBlockAndWait {
            // GIVEN
            self.mockSyncStatus.mockPhase = .fetchingFeatureFlags

            guard
                let teamId = self.selfUser.teamIdentifier?.uuidString,
                let request = self.sut.nextRequest()
            else {
                return XCTFail()
            }

            // WHEN
            let encoder = JSONEncoder()
            let data = try! encoder.encode(SignatureFeatureFlagResponse(status: false))
            let urlResponse = HTTPURLResponse(url: URL(string: "/teams/\(teamId)/features/digital-signatures")!,
                                              statusCode: 200,
                                              httpVersion: nil,
                                              headerFields: nil)!
            let response = ZMTransportResponse(httpurlResponse: urlResponse,
                                               data: data,
                                               error: nil)
            request.complete(with: response)
        }
        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        // THEN
        syncMOC.performGroupedBlockAndWait {
            XCTAssertTrue(self.mockSyncStatus.didCallFinishCurrentSyncPhase)
        }
    }

    func testThatItFinishSlowSyncPhase_WhenFeatureFlagsDontExist() {
        syncMOC.performGroupedBlockAndWait {
            // GIVEN
            self.mockSyncStatus.mockPhase = .fetchingFeatureFlags
            guard let request = self.sut.nextRequest() else {
                return XCTFail()
            }

            // WHEN
            request.complete(with: ZMTransportResponse(payload: nil,
                                                       httpStatus: 404,
                                                       transportSessionError: nil))
        }
        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        // THEN
        syncMOC.performGroupedBlockAndWait {
            XCTAssertTrue(self.mockSyncStatus.didCallFinishCurrentSyncPhase)
        }
    }

    func testThatItGeneratesCorrectRequestIfFeatureFlagUpdatedMoreThan24HoursAgo() {
        let calendar = Calendar.current
        guard
            let lastUpdateDate = calendar.date(byAdding: .day, value: -2, to: Date()),
            let teamId = self.selfUser.teamIdentifier?.uuidString
        else {
            return XCTFail()
        }

        syncMOC.performGroupedBlockAndWait {
            // GIVEN
            let featureFlag = FeatureFlag.updateOrCreate(with: .digitalSignature,
                                                         value: true,
                                                         team: self.team,
                                                         context: self.syncMOC)
            featureFlag.updatedTimestamp = lastUpdateDate
            self.syncMOC.saveOrRollback()
        }

        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        let request = sut.nextRequestIfAllowed()
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.path, "/teams/\(teamId)/features/digital-signatures")
        XCTAssertEqual(request?.method, .methodGET)
    }

    func testThatItItUpdatesSignatureFeatureFlag() {
        let updatedValue = true

        syncMOC.performGroupedBlockAndWait {
            // GIVEN
            let featureFlag = FeatureFlag.updateOrCreate(with: .digitalSignature,
                                                         value: updatedValue,
                                                         team: self.team,
                                                         context: self.syncMOC)
            featureFlag.isEnabled = updatedValue
            self.syncMOC.saveOrRollback()
        }
        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        // THEN
        syncMOC.performGroupedBlockAndWait {
            let featureFlag = FeatureFlag.fetch(with: .digitalSignature,
                                                team: self.team,
                                                context: self.syncMOC)
            XCTAssertEqual(featureFlag?.isEnabled, updatedValue)
        }
    }
}
