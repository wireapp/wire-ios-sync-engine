//
// Wire
// Copyright (C) 2022 Wire Swiss GmbH
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
@testable import WireSyncEngine
import WireDataModel

class ZMUserSessionTests_MLS: MessagingTest {

    var mockCoreCryptoSetup: MockCoreCryptoSetup!
    var sut: ZMUserSession!

    override func setUp() {
        super.setUp()

        mockCoreCryptoSetup = MockCoreCryptoSetup.default
    }

    override func tearDown() {
        sut.tearDown()
        sut = nil
        mockCoreCryptoSetup = nil
        super.tearDown()
    }

    func test_ItSetsUpMLSController_OnInit() {
        // GIVEN
        createSelfClient()

        let selfUser = ZMUser.selfUser(in: syncMOC)
        selfUser.domain = "example.domain.com"

        XCTAssertNil(syncMOC.mlsController)

        // WHEN
        createSut(with: selfUser)

        // THEN
        XCTAssertNotNil(syncMOC.mlsController)
    }

    func test_ItDoesNotSetUpMLSController_WhenThereIsNoSelfClient() {
        // GIVEN
        let selfUser = ZMUser.selfUser(in: syncMOC)
        selfUser.remoteIdentifier =  UUID.create()
        selfUser.domain = "example.domain.com"

        XCTAssertNil(syncMOC.mlsController)

        // WHEN
        createSut(with: selfUser)

        // THEN
        XCTAssertNil(syncMOC.mlsController)
    }

    func test_ItSetsUpMLSController_AfterRegisteringSelfClient() {
        // GIVEN
        let selfUser = ZMUser.selfUser(in: syncMOC)
        selfUser.remoteIdentifier =  UUID.create()
        selfUser.domain = "example.domain.com"

        createSut(with: selfUser)

        XCTAssertNil(syncMOC.mlsController)

        let client = createSelfClient()

        // WHEN
        sut.didRegisterSelfUserClient(client)

        // THEN
        XCTAssertNotNil(syncMOC.mlsController)
    }

    func test_ItCommitsPendingProposals_AfterQuickSyncCompletes() {
        // GIVEN
        let converation = ZMConversation.insertNewObject(in: syncMOC)
        converation.mlsGroupID = MLSGroupID("123".data(using: .utf8)!)
        converation.commitPendingProposalDate = Date.distantPast

        let selfUser = ZMUser.selfUser(in: syncMOC)
        selfUser.remoteIdentifier =  UUID.create()
        selfUser.domain = "example.domain.com"

        createSut(with: selfUser)
        let client = createSelfClient()
        sut.didRegisterSelfUserClient(client)

        // WHEN
        sut.didFinishQuickSync()

        // THEN
        XCTAssertTrue(wait(withTimeout: 3.0) { [self] in
            !(mockCoreCryptoSetup.mockCoreCrypto?.calls.wire_commitPendingProposals.isEmpty ?? true)
        })
        let wire_commitPendingProposalsCalls = mockCoreCryptoSetup.mockCoreCrypto?.calls.wire_commitPendingProposals
        XCTAssertEqual(1, wire_commitPendingProposalsCalls?.count)
        XCTAssertEqual(converation.mlsGroupID?.bytes, wire_commitPendingProposalsCalls?[0])
    }

    func createSut(with user: ZMUser) {
        let transportSession = RecordingMockTransportSession(
            cookieStorage: ZMPersistentCookieStorage(
                forServerName: "usersessiontest.example.com",
                userIdentifier: .create()
            ),
            pushChannel: MockPushChannel()
        )

        sut = ZMUserSession(
            userId: user.remoteIdentifier,
            transportSession: transportSession,
            mediaManager: MockMediaManager(),
            flowManager: FlowManagerMock(),
            analytics: nil,
            eventProcessor: MockUpdateEventProcessor(),
            strategyDirectory: MockStrategyDirectory(),
            syncStrategy: nil,
            operationLoop: nil,
            application: application,
            appVersion: "00000",
            coreDataStack: coreDataStack,
            configuration: .init(),
            coreCryptoSetup: mockCoreCryptoSetup.setup
        )
    }
}
