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

import XCTest

@testable import WireSyncEngine

class Conversation_ParticipantsTests: DatabaseTest {
    
    var mockTransportSession: MockTransportSession!
    var mockUpdateEventProcessor: MockUpdateEventProcessor!
    
    override func setUp() {
        super.setUp()
        
        mockTransportSession = MockTransportSession(dispatchGroup: dispatchGroup)
        mockUpdateEventProcessor = MockUpdateEventProcessor()
    }
    
    override func tearDown() {
        _ = waitForAllGroupsToBeEmpty(withTimeout: 0.5)
        
        mockTransportSession.cleanUp()
        mockTransportSession = nil
        mockUpdateEventProcessor = nil
        
        super.tearDown()
    }
    
    func responsePayloadForUserEventInConversation(_ conversationId: UUID, senderId: UUID, usersIds: [UUID], eventType: String, time: Date = Date()) -> ZMTransportData {
        return ["conversation": conversationId.transportString(),
                "data": usersIds.map({ $0.transportString() }),
                "from": senderId.transportString(),
                "time": time.transportString(),
                "type": eventType] as ZMTransportData
    }
    
    // MARK: - Adding participants
    
    func testThatItParsesAllKnownAddParticipantErrorResponses() {
        
        let errorResponses: [(ConversationAddParticipantsError, ZMTransportResponse)] = [
            (ConversationAddParticipantsError.invalidOperation, ZMTransportResponse(payload: ["label": "invalid-op"] as ZMTransportData, httpStatus: 403, transportSessionError: nil)),
            (ConversationAddParticipantsError.accessDenied, ZMTransportResponse(payload: ["label": "access-denied"] as ZMTransportData, httpStatus: 403, transportSessionError: nil)),
            (ConversationAddParticipantsError.notConnectedToUser, ZMTransportResponse(payload: ["label": "not-connected"] as ZMTransportData, httpStatus: 403, transportSessionError: nil)),
            (ConversationAddParticipantsError.conversationNotFound, ZMTransportResponse(payload: ["label": "no-conversation"] as ZMTransportData, httpStatus: 404, transportSessionError: nil)),
            (ConversationAddParticipantsError.missingLegalHoldConsent, ZMTransportResponse(payload: ["label": "missing-legalhold-consent"] as ZMTransportData, httpStatus: 412, transportSessionError: nil)),
        ]
        
        for (expectedError, response) in errorResponses {
            guard let error = ConversationAddParticipantsError(response: response) else { return XCTFail() }
            
            if case error = expectedError {
                // success
            } else {
                XCTFail()
            }
        }
    }
    
    func testThatAddingParticipantsForwardEventInResponseToEventConsumers() {
        
        // given
        let user = ZMUser.insertNewObject(in: uiMOC)
        user.remoteIdentifier = UUID()
        
        let conversation = ZMConversation.insertGroupConversation(moc: uiMOC, participants: [])!
        conversation.remoteIdentifier = UUID()
        conversation.conversationType = .group
        
        mockTransportSession.responseGeneratorBlock = { request in
            guard request.path == "/conversations/\(conversation.remoteIdentifier!.transportString())/members" else { return nil }
            
            let payload = self.responsePayloadForUserEventInConversation(conversation.remoteIdentifier!, senderId: UUID(), usersIds: [user.remoteIdentifier!], eventType: EventConversationMemberJoin)
            return ZMTransportResponse(payload: payload, httpStatus: 200, transportSessionError: nil)
        }
        
        let receivedSuccess = expectation(description: "received success")
        
        // when
        conversation.addParticipants([user], transportSession: mockTransportSession, eventProcessor: mockUpdateEventProcessor, contextProvider: coreDataStack!) { result in
            switch result {
            case .success:
                receivedSuccess.fulfill()
            default: break
            }
        }
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(mockUpdateEventProcessor.processedEvents.count, 1);
        XCTAssertEqual(mockUpdateEventProcessor.processedEvents.first?.type, .conversationMemberJoin)
        
        mockTransportSession.responseGeneratorBlock = nil
        mockTransportSession.resetReceivedRequests()
    }
    
    func testThatAddingParticipantsFailWhenAddingSelfUser() {
        
        // given
        let selfUser = ZMUser.selfUser(in: uiMOC)
        selfUser.remoteIdentifier = UUID()
        
        let conversation = ZMConversation.insertGroupConversation(moc: uiMOC, participants: [])!
        conversation.remoteIdentifier = UUID()
        conversation.conversationType = .group
        
        let receivedError = expectation(description: "received error")
        
        // when
        conversation.addParticipants([selfUser], transportSession: mockTransportSession, eventProcessor: mockUpdateEventProcessor, contextProvider: coreDataStack!) { result in
            switch result {
            case .failure(let error):
                if case ConversationAddParticipantsError.invalidOperation = error {
                    receivedError.fulfill()
                }
            default: break
            }
        }
        
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatAddingParticipantsFailForConversationTypesButGroups() {
        
        // given
        let user = ZMUser.insertNewObject(in: uiMOC)
        user.remoteIdentifier = UUID()
        
        for conversationType in [ZMConversationType.connection, ZMConversationType.oneOnOne, ZMConversationType.`self`, ZMConversationType.invalid] {
            let conversation = ZMConversation.insertGroupConversation(moc: uiMOC, participants: [])!
            conversation.remoteIdentifier = UUID()
            conversation.conversationType = conversationType
            
            let receivedError = expectation(description: "received error")
            
            // when
            conversation.addParticipants([user], transportSession: mockTransportSession, eventProcessor: mockUpdateEventProcessor, contextProvider: coreDataStack!) { result in
                switch result {
                case .failure(let error):
                    if case ConversationAddParticipantsError.invalidOperation = error {
                        receivedError.fulfill()
                    }
                default: break
                }
            }
            
            XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
        }
    }
    
    func testThatAddParticipantsFailOnInvalidOperation() {
        
        // given
        let user = ZMUser.insertNewObject(in: uiMOC)
        user.remoteIdentifier = UUID()
        
        let conversation = ZMConversation.insertGroupConversation(moc: uiMOC, participants: [])!
        conversation.remoteIdentifier = UUID()
        conversation.conversationType = .group
        
        mockTransportSession.responseGeneratorBlock = { request in
            guard request.path == "/conversations/\(conversation.remoteIdentifier!.transportString())/members" else { return nil }
            
            return ZMTransportResponse(payload: ["label": "invalid-op"] as ZMTransportData, httpStatus: 403, transportSessionError: nil)
        }
        
        let receivedError = expectation(description: "received error")
        
        // when
        conversation.addParticipants([user], transportSession: mockTransportSession, eventProcessor: mockUpdateEventProcessor, contextProvider: coreDataStack!) { result in
            switch result {
            case .failure(let error):
                if case ConversationAddParticipantsError.invalidOperation = error {
                    receivedError.fulfill()
                }
            default: break
            }
        }
        
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
        mockTransportSession.responseGeneratorBlock = nil
        mockTransportSession.resetReceivedRequests()
    }
    
    func testThatAddParticipantsFailOnConversationNotFound() {
        
        // given
        let user = ZMUser.insertNewObject(in: uiMOC)
        user.remoteIdentifier = UUID()
        
        let conversation = ZMConversation.insertGroupConversation(moc: uiMOC, participants: [user])!
        conversation.remoteIdentifier = UUID()
        conversation.conversationType = .group
        
        
        mockTransportSession.responseGeneratorBlock = { request in
            guard request.path == "/conversations/\(conversation.remoteIdentifier!.transportString())/members" else { return nil }
            
            return ZMTransportResponse(payload: ["label": "no-conversation"] as ZMTransportData, httpStatus: 404, transportSessionError: nil)
        }
        
        let receivedError = expectation(description: "received error")
        
        // when
        conversation.addParticipants([user], transportSession: mockTransportSession, eventProcessor: mockUpdateEventProcessor, contextProvider: coreDataStack!) { result in
            switch result {
            case .failure(let error):
                if case ConversationAddParticipantsError.conversationNotFound = error {
                    receivedError.fulfill()
                }
            default: break
            }
        }
        
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
        mockTransportSession.responseGeneratorBlock = nil
        mockTransportSession.resetReceivedRequests()
    }
    
    func testThatAddParticipantsRefetchTeamUsersOnInvalidOperation() {
        
        // given
        let team = Team.insertNewObject(in: self.uiMOC)
        team.name = "Wire Amazing Team"
        
        let selfUser = ZMUser.selfUser(in: self.uiMOC)
        
        let teamUser = ZMUser.insertNewObject(in: uiMOC)
        teamUser.remoteIdentifier = UUID()
        teamUser.needsToBeUpdatedFromBackend = false
        
        let nonTeamUser = ZMUser.insertNewObject(in: uiMOC)
        nonTeamUser.remoteIdentifier = UUID()
        nonTeamUser.needsToBeUpdatedFromBackend = false
        
        self.performPretendingUIMocIsSyncMoc {
            _ = Member.getOrCreateMember(for: selfUser, in: team, context: self.uiMOC)
            _ = Member.getOrCreateMember(for: teamUser, in: team, context: self.uiMOC)
        }
        
        let conversation = ZMConversation.insertGroupConversation(moc: uiMOC, participants: [])!
        conversation.remoteIdentifier = UUID()
        conversation.conversationType = .group
        
        mockTransportSession.responseGeneratorBlock = { request in
            guard request.path == "/conversations/\(conversation.remoteIdentifier!.transportString())/members" else { return nil }
            
            return ZMTransportResponse(payload: ["label": "invalid-op"] as ZMTransportData, httpStatus: 403, transportSessionError: nil)
        }
        
        let receivedError = expectation(description: "received error")
        
        // when
        conversation.addParticipants([teamUser, nonTeamUser], transportSession: mockTransportSession, eventProcessor: mockUpdateEventProcessor, contextProvider: coreDataStack!) { result in
            switch result {
            case .failure(let error):
                if case ConversationAddParticipantsError.invalidOperation = error {
                    receivedError.fulfill()
                }
            default: break
            }
        }
        
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
        mockTransportSession.responseGeneratorBlock = nil
        mockTransportSession.resetReceivedRequests()
        
        // then
        XCTAssertTrue(teamUser.needsToBeUpdatedFromBackend)
        XCTAssertFalse(nonTeamUser.needsToBeUpdatedFromBackend)
    }
    
    // MARK: - Removing participant
    
    func testThatItParsesAllKnownRemoveParticipantErrorResponses() {
        
        let errorResponses: [(ConversationRemoveParticipantError, ZMTransportResponse)] = [
            (ConversationRemoveParticipantError.invalidOperation, ZMTransportResponse(payload: ["label": "invalid-op"] as ZMTransportData, httpStatus: 403, transportSessionError: nil)),
            (ConversationRemoveParticipantError.conversationNotFound, ZMTransportResponse(payload: ["label": "no-conversation"] as ZMTransportData, httpStatus: 404, transportSessionError: nil))
        ]
        
        for (expectedError, response) in errorResponses {
            guard let error = ConversationRemoveParticipantError(response: response) else { return XCTFail() }
            
            if case error = expectedError {
                // success
            } else {
                XCTFail()
            }
        }
    }
    
    func testThatRemoveParticipantSucceedsOnNoChange() {
        
        // given
        let user = ZMUser.insertNewObject(in: uiMOC)
        user.remoteIdentifier = UUID()
        
        let conversation = ZMConversation.insertGroupConversation(moc: uiMOC, participants: [user])!
        conversation.remoteIdentifier = UUID()
        conversation.conversationType = .group
        
        
        mockTransportSession.responseGeneratorBlock = { request in
            guard request.path == "/conversations/\(conversation.remoteIdentifier!.transportString())/members/\(user.remoteIdentifier!.transportString())" else { return nil }
            
            return ZMTransportResponse(payload: nil, httpStatus: 204, transportSessionError: nil)
        }
        
        let receivedSuccess = expectation(description: "received success")
        
        // when
        conversation.removeParticipant(user, transportSession: mockTransportSession, eventProcessor: mockUpdateEventProcessor, contextProvider: coreDataStack!) { result in
            switch result {
            case .success:
                receivedSuccess.fulfill()
            default: break
            }
        }
        
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
        mockTransportSession.responseGeneratorBlock = nil
        mockTransportSession.resetReceivedRequests()
    }
    
    func testThatRemovingParticipantFailForAllConversationTypesButGroups() {
        
        // given
        let user = ZMUser.insertNewObject(in: uiMOC)
        user.remoteIdentifier = UUID()
        
        for conversationType in [ZMConversationType.connection, ZMConversationType.oneOnOne, ZMConversationType.`self`, ZMConversationType.invalid] {
            let conversation = ZMConversation.insertGroupConversation(moc: uiMOC, participants: [])!
            conversation.remoteIdentifier = UUID()
            conversation.conversationType = conversationType
            
            let receivedError = expectation(description: "received error")
            
            // when
            conversation.removeParticipant(user, transportSession: mockTransportSession, eventProcessor: mockUpdateEventProcessor, contextProvider: coreDataStack!) { result in
                switch result {
                case .failure(let error):
                    if case ConversationRemoveParticipantError.invalidOperation = error {
                        receivedError.fulfill()
                    }
                default: break
                }
            }
            
            XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
        }
    }
    
    func testThatRemoveParticipantFailOnInvalidOperation() {
        
        // given
        let user = ZMUser.insertNewObject(in: uiMOC)
        user.remoteIdentifier = UUID()
        
        let conversation = ZMConversation.insertGroupConversation(moc: uiMOC, participants: [user])!
        conversation.remoteIdentifier = UUID()
        conversation.conversationType = .group
        
        
        mockTransportSession.responseGeneratorBlock = { request in
            guard request.path == "/conversations/\(conversation.remoteIdentifier!.transportString())/members/\(user.remoteIdentifier!.transportString())" else { return nil }
            
            return ZMTransportResponse(payload: ["label": "invalid-op"] as ZMTransportData, httpStatus: 403, transportSessionError: nil)
        }
        
        let receivedError = expectation(description: "received error")
        
        // when
        conversation.removeParticipant(user, transportSession: mockTransportSession, eventProcessor: mockUpdateEventProcessor, contextProvider: coreDataStack!) { result in
            switch result {
            case .failure(let error):
                if case ConversationRemoveParticipantError.invalidOperation = error {
                    receivedError.fulfill()
                }
            default: break
            }
        }
        
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
        mockTransportSession.responseGeneratorBlock = nil
        mockTransportSession.resetReceivedRequests()
    }
    
    func testThatRemoveParticipantFailOnConversationNotFound() {
        
        // given
        let user = ZMUser.insertNewObject(in: uiMOC)
        user.remoteIdentifier = UUID()
        
        let conversation = ZMConversation.insertGroupConversation(moc: uiMOC, participants: [user])!
        conversation.remoteIdentifier = UUID()
        conversation.conversationType = .group
        
        
        mockTransportSession.responseGeneratorBlock = { request in
            guard request.path == "/conversations/\(conversation.remoteIdentifier!.transportString())/members/\(user.remoteIdentifier!.transportString())" else { return nil }
            
            return ZMTransportResponse(payload: ["label": "no-conversation"] as ZMTransportData, httpStatus: 404, transportSessionError: nil)
        }
        
        let receivedError = expectation(description: "received error")
        
        // when
        conversation.removeParticipant(user, transportSession: mockTransportSession, eventProcessor: mockUpdateEventProcessor, contextProvider: coreDataStack!) { result in
            switch result {
            case .failure(let error):
                if case ConversationRemoveParticipantError.conversationNotFound = error {
                    receivedError.fulfill()
                }
            default: break
            }
        }
        
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
        mockTransportSession.responseGeneratorBlock = nil
        mockTransportSession.resetReceivedRequests()
    }
    
    func testThatRemoveParticipantForwardEventInResponseToEventConsumers() {
        
        // given
        let user = ZMUser.insertNewObject(in: uiMOC)
        user.remoteIdentifier = UUID()

        let conversation = ZMConversation.insertGroupConversation(moc: uiMOC, participants: [user])!
        conversation.remoteIdentifier = UUID()
        conversation.conversationType = .group

        mockTransportSession.responseGeneratorBlock = { request in
            guard request.path == "/conversations/\(conversation.remoteIdentifier!.transportString())/members/\(user.remoteIdentifier!.transportString())" else { return nil }

            let payload = self.responsePayloadForUserEventInConversation(conversation.remoteIdentifier!, senderId: UUID(), usersIds: [user.remoteIdentifier!], eventType: EventConversationMemberLeave)
            return ZMTransportResponse(payload: payload, httpStatus: 200, transportSessionError: nil)
        }

        let receivedSuccess = expectation(description: "received success")

        // when
        conversation.removeParticipant(user, transportSession: mockTransportSession, eventProcessor: mockUpdateEventProcessor, contextProvider: coreDataStack!) { result in
            switch result {
            case .success:
                receivedSuccess.fulfill()
            default: break
            }
        }
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(mockUpdateEventProcessor.processedEvents.count, 1);
        XCTAssertEqual(mockUpdateEventProcessor.processedEvents.first?.type, .conversationMemberLeave)
        
        mockTransportSession.responseGeneratorBlock = nil
        mockTransportSession.resetReceivedRequests()
    }
    
    func testThatClearedTimestampAreUpdatedWhenRemovingSelf() {
        
        // given
        let user = ZMUser.insertNewObject(in: uiMOC)
        user.remoteIdentifier = UUID()
        
        let selfUser = ZMUser.selfUser(in: uiMOC)
        selfUser.remoteIdentifier = UUID()
        
        let conversationId = UUID()
        let conversation = ZMConversation.insertGroupConversation(moc: uiMOC, participants: [user])!
        conversation.remoteIdentifier = conversationId
        conversation.conversationType = .group;

        let message = ZMClientMessage(nonce: UUID(), managedObjectContext: uiMOC)
        message.serverTimestamp = Date()
        conversation.mutableMessages.add(message)
        conversation.lastServerTimeStamp = message.serverTimestamp?.addingTimeInterval(5)
        
        conversation.clearMessageHistory()
        uiMOC.saveOrRollback()
        
        let memberLeaveTimestamp = Date().addingTimeInterval(1000)
        let receivedSuccess = expectation(description: "received success")
        
        mockTransportSession.responseGeneratorBlock = { request in
            guard request.path == "/conversations/\(conversation.remoteIdentifier!.transportString())/members/\(selfUser.remoteIdentifier!.transportString())" else { return nil }
            
            let payload = self.responsePayloadForUserEventInConversation(conversation.remoteIdentifier!, senderId: UUID(), usersIds: [user.remoteIdentifier!], eventType: EventConversationMemberLeave, time: memberLeaveTimestamp)
            return ZMTransportResponse(payload: payload, httpStatus: 200, transportSessionError: nil)
        }
        
        // when
        conversation.removeParticipant(selfUser, transportSession: mockTransportSession, eventProcessor: mockUpdateEventProcessor, contextProvider: coreDataStack!) { result in
            switch result {
            case .success:
                receivedSuccess.fulfill()
            default: break
            }
        }
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        syncMOC.saveOrRollback()
        
        // then
        syncMOC.performGroupedBlockAndWait {
            let conversation = ZMConversation.fetch(with: conversationId, in: self.syncMOC)!
            XCTAssertEqual(conversation.clearedTimeStamp?.transportString(), memberLeaveTimestamp.transportString())
        }
        
        mockTransportSession.responseGeneratorBlock = nil
        mockTransportSession.resetReceivedRequests()
    }
    
    func testThatClearedTimestampAreNotUpdatedWhenRemovingOtherUser() {
        
        // given
        let user = ZMUser.insertNewObject(in: uiMOC)
        user.remoteIdentifier = UUID()
        
        let selfUser = ZMUser.selfUser(in: uiMOC)
        selfUser.remoteIdentifier = UUID()
        
        let conversationId = UUID()
        let conversation = ZMConversation.insertGroupConversation(moc: uiMOC, participants: [user])!
        conversation.remoteIdentifier = conversationId
        conversation.conversationType = .group;
        
        let message = ZMClientMessage(nonce: UUID(), managedObjectContext: uiMOC)
        message.serverTimestamp = Date()
        conversation.mutableMessages.add(message)
        conversation.lastServerTimeStamp = message.serverTimestamp?.addingTimeInterval(5)
        
        conversation.clearMessageHistory()
        uiMOC.saveOrRollback()
        
        let clearedTimestamp = conversation.clearedTimeStamp
        let memberLeaveTimestamp = Date().addingTimeInterval(1000)
        let receivedSuccess = expectation(description: "received success")
        
        mockTransportSession.responseGeneratorBlock = { request in
            guard request.path == "/conversations/\(conversation.remoteIdentifier!.transportString())/members/\(user.remoteIdentifier!.transportString())" else { return nil }
            
            let payload = self.responsePayloadForUserEventInConversation(conversation.remoteIdentifier!, senderId: UUID(), usersIds: [user.remoteIdentifier!], eventType: EventConversationMemberLeave, time: memberLeaveTimestamp)
            return ZMTransportResponse(payload: payload, httpStatus: 200, transportSessionError: nil)
        }
        
        // when
        conversation.removeParticipant(user, transportSession: mockTransportSession, eventProcessor: mockUpdateEventProcessor, contextProvider: coreDataStack!) { result in
            switch result {
            case .success:
                receivedSuccess.fulfill()
            default: break
            }
        }
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        syncMOC.saveOrRollback()
        
        // then
        syncMOC.performGroupedBlockAndWait {
            let conversation = ZMConversation.fetch(with: conversationId, in: self.syncMOC)!
            XCTAssertEqual(conversation.clearedTimeStamp?.transportString(), clearedTimestamp?.transportString())
        }
        
        mockTransportSession.responseGeneratorBlock = nil
        mockTransportSession.resetReceivedRequests()
    }
    
    // MARK: - Request Factory
    
    func testThatItCreatesRequestForRemovingService() {
        
        // given
        let service = ZMUser.insertNewObject(in: uiMOC)
        service.remoteIdentifier = UUID()
        service.providerIdentifier = "123"
        service.serviceIdentifier = "123"
        
        let conversation = ZMConversation.insertGroupConversation(moc: uiMOC, participants: [service])!
        conversation.remoteIdentifier = UUID()
        
        // when
        let request = WireSyncEngine.ConversationParticipantRequestFactory.requestForRemovingParticipant(service, conversation: conversation)
        
        // then
        XCTAssertEqual(request.method, .methodDELETE)
        XCTAssertEqual(request.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/bots/\(service.remoteIdentifier!.transportString())")
    }
    
    func testThatItCreatesRequestForRemovingParticipant() {
        
        // given
        let user = ZMUser.insertNewObject(in: uiMOC)
        user.remoteIdentifier = UUID()
        
        let conversation = ZMConversation.insertGroupConversation(moc: uiMOC, participants: [user])!
        conversation.remoteIdentifier = UUID()
        
        // when
        let request = WireSyncEngine.ConversationParticipantRequestFactory.requestForRemovingParticipant(user, conversation: conversation)
        
        // then
        XCTAssertEqual(request.method, .methodDELETE)
        XCTAssertEqual(request.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/members/\(user.remoteIdentifier!.transportString())")
    }
    
    func testThatItCreatesRequestForAddingParticipants() {
        
        // given
        let user1 = ZMUser.insertNewObject(in: uiMOC)
        user1.remoteIdentifier = UUID()
        
        let user2 = ZMUser.insertNewObject(in: uiMOC)
        user2.remoteIdentifier = UUID()
        
        let conversation = ZMConversation.insertGroupConversation(moc: uiMOC, participants: [])!
        conversation.remoteIdentifier = UUID()
        
        // when
        let request = WireSyncEngine.ConversationParticipantRequestFactory.requestForAddingParticipants(Set(arrayLiteral: user1, user2), conversation: conversation)
        
        // then
        XCTAssertEqual(request.method, .methodPOST)
        XCTAssertEqual(request.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/members")

        let payload = request.payload?.asDictionary()
        XCTAssertNotNil(payload)

        let usersIdsInPayload = payload!["users"] as! [String]
        XCTAssertEqual(Set(usersIdsInPayload), Set(arrayLiteral: user1.remoteIdentifier!.transportString(), user2.remoteIdentifier!.transportString()))

        let conversationRole = payload!["conversation_role"] as! String
        XCTAssertEqual(conversationRole, ZMConversation.defaultMemberRoleName)
    }
    
}
