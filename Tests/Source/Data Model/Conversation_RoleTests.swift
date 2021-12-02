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
@testable import WireSyncEngine

class Conversation_RoleTests: MessagingTest {

    typealias Factory = WireSyncEngine.ConversationRoleRequestFactory

    // MARK: - Input Assertions

    func testThatRequestIsCorrectForValidInputs() {
        // Given
        let user = ZMUser.insertNewObject(in: uiMOC)
        user.remoteIdentifier = UUID.create()

        let conversation = ZMConversation.insertNewObject(in: uiMOC)
        conversation.remoteIdentifier = UUID.create()

        let role = Role.insertNewObject(in: uiMOC)
        role.name = "wire_admin"

        // When
        guard let request = Factory.requestForUpdatingParticipantRole(role, for: user, in: conversation) else {
            return XCTFail("Could not create request")
        }

        // Then
        XCTAssertEqual(request.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/members/\(user.remoteIdentifier!.transportString())")
        XCTAssertEqual(request.method, .methodPUT)
        XCTAssertEqual(request.payload?.asDictionary() as? [String: String], ["conversation_role": "wire_admin"])
    }

    func testThatRequestFailsWhenRoleNameIsMissing() {
        // Given
        let user = ZMUser.insertNewObject(in: uiMOC)
        user.remoteIdentifier = UUID.create()

        let conversation = ZMConversation.insertNewObject(in: uiMOC)
        conversation.remoteIdentifier = UUID.create()

        let role = Role.insertNewObject(in: uiMOC)
        role.name = nil

        let expectation = self.expectation(description: "completed")

        // When
        let request = Factory.requestForUpdatingParticipantRole(role, for: user, in: conversation) { result in
            switch result {
            case .success: XCTFail("The request did not fail")
            default: break
            }

            expectation.fulfill()
        }

        // Then
        XCTAssert(waitForCustomExpectations(withTimeout: 0.5))
        XCTAssertNil(request)
    }

    func testThatRequestFailsWhenUserIdIsMissing() {
        // Given
        let user = ZMUser.insertNewObject(in: uiMOC)
        user.remoteIdentifier = nil

        let conversation = ZMConversation.insertNewObject(in: uiMOC)
        conversation.remoteIdentifier = UUID.create()

        let role = Role.insertNewObject(in: uiMOC)
        role.name = "wire_admin"

        let expectation = self.expectation(description: "completed")

        // When
        let request = Factory.requestForUpdatingParticipantRole(role, for: user, in: conversation) { result in
            switch result {
            case .success: XCTFail("The request did not fail")
            default: break
            }

            expectation.fulfill()
        }

        // Then
        XCTAssert(waitForCustomExpectations(withTimeout: 0.5))
        XCTAssertNil(request)
    }

    func testThatRequestFailsWhenConversationIdIsMissing() {
        // Given
        let user = ZMUser.insertNewObject(in: uiMOC)
        user.remoteIdentifier = UUID.create()

        let conversation = ZMConversation.insertNewObject(in: uiMOC)
        conversation.remoteIdentifier = nil

        let role = Role.insertNewObject(in: uiMOC)
        role.name = "wire_admin"

        let expectation = self.expectation(description: "completed")

        // When
        let request = Factory.requestForUpdatingParticipantRole(role, for: user, in: conversation) { result in
            switch result {
            case .success: XCTFail("The request did not fail")
            default: break
            }

            expectation.fulfill()
        }

        // Then
        XCTAssert(waitForCustomExpectations(withTimeout: 0.5))
        XCTAssertNil(request)
    }

    // MARK: - Request Completion Handling

    func testThatTheCompletedRequestUpdatesTheDatabase() {
        // Given
        let user = ZMUser.insertNewObject(in: uiMOC)
        user.remoteIdentifier = UUID.create()

        let conversation = ZMConversation.insertNewObject(in: uiMOC)
        conversation.remoteIdentifier = UUID.create()

        let role = Role.insertNewObject(in: uiMOC)
        role.name = "wire_admin"

        let expectation = self.expectation(description: "completed")

        // When
        let maybeRequest = Factory.requestForUpdatingParticipantRole(role, for: user, in: conversation) { result in
            switch result {
            case .failure: XCTFail("The request did not succeed")
            default: break
            }

            expectation.fulfill()
        }

        guard let request = maybeRequest else {
            return XCTFail("Could not create request")
        }

        request.complete(with: ZMTransportResponse(payload: nil, httpStatus: 200, transportSessionError: nil))

        // Then
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        XCTAssertEqual(user.participantRoles.first { $0.conversation == conversation }?.role, role)
    }

    func testThatTheFailedRequestDoesNotUpdateTheDatabase() {
        // Given
        let user = ZMUser.insertNewObject(in: uiMOC)
        user.remoteIdentifier = UUID.create()

        let conversation = ZMConversation.insertNewObject(in: uiMOC)
        conversation.remoteIdentifier = UUID.create()

        let role = Role.insertNewObject(in: uiMOC)
        role.name = "wire_admin"

        let expectation = self.expectation(description: "completed")

        // When
        let maybeRequest = Factory.requestForUpdatingParticipantRole(role, for: user, in: conversation) { result in
            switch result {
            case .success: XCTFail("The request did not fail")
            default: break
            }

            expectation.fulfill()
        }

        guard let request = maybeRequest else {
            return XCTFail("Could not create request")
        }

        request.complete(with: ZMTransportResponse(payload: nil, httpStatus: 400, transportSessionError: nil))

        // Then
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        XCTAssertTrue(user.participantRoles.isEmpty)
    }

}
