////
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

class ConversationTests_Guests: IntegrationTest {

    override func setUp() {
        super.setUp()

        createSelfUserAndConversation()
        createExtraUsersAndConversations()
        createTeamAndConversations()
    }

    func testThatItSendsRequestToChangeAccessMode() {
        // given
#if swift(>=5.4) && arch(arm64)
        XCTExpectFailure("Test is expected to fail on an m1 machine because of the login method for integration tests")
        XCTAssert(login())

        let conversation = self.conversation(for: self.groupConversationWithWholeTeam)!

        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))
        XCTAssertFalse(conversation.accessMode!.contains(.allowGuests))
        mockTransportSession?.resetReceivedRequests()

        // when
        conversation.setAllowGuests(true, in: self.userSession!) { result in
            switch result {
            case .success:
                break
            case .failure:
                XCTFail()
            }
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))

        // then
        XCTAssertTrue(conversation.accessMode!.contains(.allowGuests))
        XCTAssertEqual(mockTransportSession.receivedRequests().count, 1)
        guard let request = mockTransportSession.receivedRequests().first else { return }
        XCTAssertEqual(request.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/access")
        #endif
    }

    func testThatItSendsRequestToCreateTheLink() {
        // given
#if swift(>=5.4) && arch(arm64)
        XCTExpectFailure("Test is expected to fail on an m1 machine because of the login method for integration tests")
        mockTransportSession.performRemoteChanges { _ in
            self.groupConversationWithWholeTeam.accessMode = ["code", "invite"]
            self.groupConversationWithWholeTeam.accessRole = "non_activated"
        }
        XCTAssert(login())

        let conversation = self.conversation(for: self.groupConversationWithWholeTeam)!

        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))
        XCTAssertEqual(conversation.accessMode, [.code, .invite])
        XCTAssertEqual(conversation.accessRole, .nonActivated)
        mockTransportSession?.resetReceivedRequests()

        // when
        conversation.updateAccessAndCreateWirelessLink(in: self.userSession!) { result in
            switch result {
            case .success(let link):
                XCTAssertEqual(link, self.groupConversationWithWholeTeam.link)
            case .failure:
                XCTFail()
            }
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))

        // then
        XCTAssertEqual(mockTransportSession.receivedRequests().count, 1)
        guard let request = mockTransportSession.receivedRequests().first else { return }
        XCTAssertEqual(request.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/code")
        XCTAssertEqual(request.method, .methodPOST)
#endif
    }

    func testThatItSendsRequestToSetModeIfLegacyWhenFetchingTheLink() {
        // given
#if swift(>=5.4) && arch(arm64)
        XCTExpectFailure("Test is expected to fail on an m1 machine because of the login method for integration tests")
        mockTransportSession.performRemoteChanges { _ in
            self.groupConversationWithWholeTeam.accessMode = ["invite"]
            self.groupConversationWithWholeTeam.accessRole = "activated"
        }
        XCTAssert(login())

        let conversation = self.conversation(for: self.groupConversationWithWholeTeam)!

        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))
        XCTAssertEqual(conversation.accessMode, [.invite])
        XCTAssertEqual(conversation.accessRole, .activated)
        mockTransportSession?.resetReceivedRequests()

        // when
        conversation.updateAccessAndCreateWirelessLink(in: self.userSession!) { result in
            switch result {
            case .success(let link):
                XCTAssertEqual(link, self.groupConversationWithWholeTeam.link)
            case .failure:
                XCTFail()
            }
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))

        // then
        XCTAssertEqual(mockTransportSession.receivedRequests().count, 2)
        guard let requestFirst = mockTransportSession.receivedRequests().first else { return }
        XCTAssertEqual(requestFirst.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/access")
        guard let requestLast = mockTransportSession.receivedRequests().last else { return }
        XCTAssertEqual(requestLast.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/code")
        XCTAssertEqual(requestLast.method, .methodPOST)
#endif
    }

    func testThatItSendsRequestToFetchTheLink_NoLink() {
        // given
#if swift(>=5.4) && arch(arm64)
        XCTExpectFailure("Test is expected to fail on an m1 machine because of the login method for integration tests")
        mockTransportSession.performRemoteChanges { _ in
            self.groupConversationWithWholeTeam.accessMode = ["code", "invite"]
            self.groupConversationWithWholeTeam.accessRole = "non_activated"
        }
        XCTAssert(login())

        let conversation = self.conversation(for: self.groupConversationWithWholeTeam)!

        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))
        XCTAssertEqual(conversation.accessMode, [.code, .invite])
        XCTAssertEqual(conversation.accessRole, .nonActivated)
        mockTransportSession?.resetReceivedRequests()

        // when
        conversation.fetchWirelessLink(in: self.userSession!) { result in
            switch result {
            case .success(let link):
                XCTAssertNil(link)
            case .failure:
                XCTFail()
            }
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))

        // then
        XCTAssertEqual(mockTransportSession.receivedRequests().count, 1)
        guard let request = mockTransportSession.receivedRequests().first else { return }
        XCTAssertEqual(request.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/code")
        XCTAssertEqual(request.method, .methodGET)
#endif
    }

    func testThatItSendsRequestToFetchTheLink_LinkExists() {
        // given
#if swift(>=5.4) && arch(arm64)
        XCTExpectFailure("Test is expected to fail on an m1 machine because of the login method for integration tests")
        let existingLink = "https://wire-website.com/some-magic-link"

        mockTransportSession.performRemoteChanges { _ in
            self.groupConversationWithWholeTeam.accessMode = ["code", "invite"]
            self.groupConversationWithWholeTeam.accessRole = "non_activated"
            self.groupConversationWithWholeTeam.link = existingLink
        }
        XCTAssert(login())

        let conversation = self.conversation(for: self.groupConversationWithWholeTeam)!

        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))
        XCTAssertEqual(conversation.accessMode, [.code, .invite])
        XCTAssertEqual(conversation.accessRole, .nonActivated)
        mockTransportSession?.resetReceivedRequests()

        // when
        conversation.fetchWirelessLink(in: self.userSession!) { result in
            switch result {
            case .success(let link):
                XCTAssertEqual(link, existingLink)
            case .failure:
                XCTFail()
            }
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))

        // then
        XCTAssertEqual(mockTransportSession.receivedRequests().count, 1)
        guard let request = mockTransportSession.receivedRequests().first else { return }
        XCTAssertEqual(request.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/code")
        XCTAssertEqual(request.method, .methodGET)
#endif
    }

    func testThatItSendsRequestToDeleteTheLink() {
        // given
#if swift(>=5.4) && arch(arm64)
        XCTExpectFailure("Test is expected to fail on an m1 machine because of the login method for integration tests")
        let existingLink = "https://wire-website.com/some-magic-link"

        mockTransportSession.performRemoteChanges { _ in
            self.groupConversationWithWholeTeam.accessMode = ["code", "invite"]
            self.groupConversationWithWholeTeam.accessRole = "non_activated"
            self.groupConversationWithWholeTeam.link = existingLink
        }
        XCTAssert(login())

        let conversation = self.conversation(for: self.groupConversationWithWholeTeam)!

        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))
        XCTAssertEqual(conversation.accessMode, [.code, .invite])
        XCTAssertEqual(conversation.accessRole, .nonActivated)
        mockTransportSession?.resetReceivedRequests()

        // when
        conversation.deleteWirelessLink(in: self.userSession!) { result in
            switch result {
            case .success:
                break
            case .failure:
                XCTFail()
            }
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))

        // then
        XCTAssertEqual(mockTransportSession.receivedRequests().count, 1)
        guard let request = mockTransportSession.receivedRequests().first else { return }
        XCTAssertEqual(request.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/code")
        XCTAssertEqual(request.method, .methodDELETE)
#endif
    }

    func testThatItSendsRequestToDeleteTheLink_LinkDoesNotExist() {
        // given
#if swift(>=5.4) && arch(arm64)
        XCTExpectFailure("Test is expected to fail on an m1 machine because of the login method for integration tests")
        mockTransportSession.performRemoteChanges { _ in
            self.groupConversationWithWholeTeam.accessMode = ["code", "invite"]
            self.groupConversationWithWholeTeam.accessRole = "non_activated"
            self.groupConversationWithWholeTeam.link = nil
        }
        XCTAssert(login())

        let conversation = self.conversation(for: self.groupConversationWithWholeTeam)!

        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))
        XCTAssertEqual(conversation.accessMode, [.code, .invite])
        XCTAssertEqual(conversation.accessRole, .nonActivated)
        mockTransportSession?.resetReceivedRequests()

        // when
        conversation.deleteWirelessLink(in: self.userSession!) { result in
            switch result {
            case .success:
                XCTFail()
            case .failure:
                break
            }
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))

        // then
        XCTAssertEqual(mockTransportSession.receivedRequests().count, 1)
        guard let request = mockTransportSession.receivedRequests().first else { return }
        XCTAssertEqual(request.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/code")
        XCTAssertEqual(request.method, .methodDELETE)
#endif
    }

    func testThatAccessModeChangeEventIsHandled() {
#if swift(>=5.4) && arch(arm64)
        XCTExpectFailure("Test is expected to fail on an m1 machine because of the login method for integration tests")
        // given
        XCTAssert(login())

        let conversation = self.conversation(for: self.groupConversationWithWholeTeam!)!
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))
        XCTAssertFalse(conversation.accessMode!.contains(.allowGuests))

        // when
        mockTransportSession?.performRemoteChanges { _ in
            self.groupConversationWithWholeTeam.set(allowGuests: true)
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))

        // then
        XCTAssertTrue(conversation.accessMode!.contains(.allowGuests))
#endif
    }

}
