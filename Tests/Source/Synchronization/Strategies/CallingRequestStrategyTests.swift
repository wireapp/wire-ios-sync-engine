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

import Foundation
import WireRequestStrategy

class CallingRequestStrategyTests : MessagingTest {

    var sut: CallingRequestStrategy!
    var mockApplicationStatus: MockApplicationStatus!
    var mockRegistrationDelegate: ClientRegistrationDelegate!
    
    override func setUp() {
        super.setUp()
        mockApplicationStatus = MockApplicationStatus()
        mockApplicationStatus.mockSynchronizationState = .online
        mockRegistrationDelegate = MockClientRegistrationDelegate()
        sut = CallingRequestStrategy(
            managedObjectContext: syncMOC,
            applicationStatus: mockApplicationStatus,
            clientRegistrationDelegate: mockRegistrationDelegate,
            flowManager: FlowManagerMock(),
            callEventStatus: CallEventStatus()
        )
    }
    
    override func tearDown() {
        sut = nil
        mockRegistrationDelegate = nil
        mockApplicationStatus = nil
        super.tearDown()
    }

    // MARK: - Misc
    
    func testThatItReturnsItselfAndTheGenericMessageStrategyAsContextChangeTracker(){
        // when
        let trackers = sut.contextChangeTrackers
        
        // then
        XCTAssertTrue(trackers.first is CallingRequestStrategy)
        XCTAssertTrue(trackers.last is GenericMessageRequestStrategy)
    }

    // MARK: - Call Config
    
    func testThatItGenerateCallConfigRequestAndCallsTheCompletionHandler() {
        
        // given
        let expectedCallConfig = "{\"config\":true}"
        let receivedCallConfigExpectation = expectation(description: "Received CallConfig")
        
        sut.requestCallConfig { (callConfig, httpStatusCode) in
            if callConfig == expectedCallConfig, httpStatusCode == 200 {
                receivedCallConfigExpectation.fulfill()
            }
        }
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        let request = sut.nextRequest()
        XCTAssertEqual(request?.path, "/calls/config/v2")
        
        // when
        let payload = [ "config" : true ]
        request?.complete(with: ZMTransportResponse(payload: payload as ZMTransportData, httpStatus: 200, transportSessionError: nil))
        
        // then
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }
    
    func testThatItGeneratesOnlyOneCallConfigRequest() {
        
        // given
        sut.requestCallConfig { (_, _) in}
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // when
        let request = sut.nextRequest()
        XCTAssertNotNil(request)
        
        // then
        let secondRequest = sut.nextRequest()
        XCTAssertNil(secondRequest)
    }
    
    func testThatItGeneratesCompressedCallConfigRequest() {
        
        // given
        sut.requestCallConfig { (_, _) in}
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // when
        guard let request = sut.nextRequest() else { return XCTFail() }
        
        // then
        XCTAssertTrue(request.shouldCompress)
    }
    
    func testThatItDoesNotForwardUnsuccessfulResponses() {
        // given
        let expectedCallConfig = "{\"config\":true}"
        let receivedCallConfigExpectation = expectation(description: "Received CallConfig")
        
        sut.requestCallConfig { (callConfig, httpStatusCode) in
            if callConfig == expectedCallConfig, httpStatusCode == 200 {
                receivedCallConfigExpectation.fulfill()
            } else {
                XCTFail()
            }
        }
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        let request = sut.nextRequest()
        XCTAssertEqual(request?.path, "/calls/config/v2")
        
        // when
        let badPayload = [ "error" : "not found" ]
        request?.complete(with: ZMTransportResponse(payload: badPayload as ZMTransportData, httpStatus: 412, transportSessionError: nil))
        
        // when
        let payload = [ "config" : true ]
        request?.complete(with: ZMTransportResponse(payload: payload as ZMTransportData, httpStatus: 200, transportSessionError: nil))

        // then
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))

    }

    // MARK: - Client List

    func testThatItGenerateClientListRequestAndCallsTheCompletionHandler() {
        // Given
        createSelfClient()

        let conversationId = UUID.create()
        let userId1 = UUID.create()
        let userId2 = UUID.create()
        let clientId1 = "client1"
        let clientId2 = "client2"

        let payload = """
        {
            "missing": {
                "\(userId1.transportString())": ["\(clientId1)", "\(clientId2)"],
                "\(userId2.transportString())": ["\(clientId1)"]
            }
        }
        """

        let receivedClientList = expectation(description: "Received client list")

        // When
        sut.requestClientsList(conversationId: conversationId) { clients in
            // Then
            XCTAssertEqual(clients.count, 3)
            XCTAssertTrue(clients.contains(AVSClient(userId: userId1, clientId: clientId1)))
            XCTAssertTrue(clients.contains(AVSClient(userId: userId1, clientId: clientId2)))
            XCTAssertTrue(clients.contains(AVSClient(userId: userId2, clientId: clientId1)))
            receivedClientList.fulfill()
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        let request = sut.nextRequest()
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.path, "/conversations/\(conversationId.transportString())/otr/messages")

        // When
        request?.complete(with: ZMTransportResponse(payload: payload as ZMTransportData, httpStatus: 412, transportSessionError: nil))

        // Then
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }

    func testThatItGeneratesOnlyOneClientListRequest() {
        // Given
        createSelfClient()

        // When
        sut.requestClientsList(conversationId: .create()) { _ in }
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        // Then
        let request = sut.nextRequest()
        XCTAssertNotNil(request)

        let secondRequest = sut.nextRequest()
        XCTAssertNil(secondRequest)
    }

    // MARK: - Targeted Calling Messages

    func testThatItTargetsCallMessagesIfTargetClientsAreSpecified() {
        // Given
        let selfClient = createSelfClient()

        // One user with two clients connected to self
        let user1 = ZMUser.insertNewObject(in: syncMOC)
        user1.remoteIdentifier = .create()

        let client1 = createClient(for: user1, connectedTo: selfClient)
        createClient(for: user1, connectedTo: selfClient)

        // Another user with two clients connected to self
        let user2 = ZMUser.insertNewObject(in: syncMOC)
        user2.remoteIdentifier = .create()

        let client2 = createClient(for: user2, connectedTo: selfClient)
        createClient(for: user2, connectedTo: selfClient)

        // A conversation with both users and self
        let conversation = ZMConversation.insertNewObject(in: syncMOC)
        conversation.remoteIdentifier = .create()
        conversation.addParticipantsAndUpdateConversationState(users: Set(arrayLiteral: ZMUser.selfUser(in: syncMOC), user1, user2), role: nil)
        conversation.needsToBeUpdatedFromBackend = false

        syncMOC.saveOrRollback()

        // Targeting two specific clients
        let avsClient1 = AVSClient(userId: user1.remoteIdentifier, clientId: client1.remoteIdentifier!)
        let avsClient2 = AVSClient(userId: user2.remoteIdentifier, clientId: client2.remoteIdentifier!)
        let targets = [avsClient1, avsClient2]

        var nextRequest: ZMTransportRequest?

        // When we schedule the targeted message
        syncMOC.performGroupedBlock {
            self.sut.send(data: Data(), conversationId: conversation.remoteIdentifier!, targets: targets) { _ in }
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        syncMOC.performGroupedBlock {
            nextRequest = self.sut.nextRequest()
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        guard let request = nextRequest else { return XCTFail("Expected next request") }

        // Then we tell backend to ignore missing clients (the non targeted conversation participants)
        XCTAssertEqual(request.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/otr/messages?ignore_missing=true")

        guard
            let data = request.binaryData,
            let otrMessage = try? NewOtrMessage(serializedData: data)
        else {
            return XCTFail("Expected OTR message")
        }

        // Then we send the message to the targeted clients
        XCTAssertEqual(otrMessage.recipients.count, 2)

        guard let recipient1 = otrMessage.recipients.first(where: { $0.user == user1.userId }) else {
            return XCTFail("Expected user1 to be recipient")
        }

        XCTAssertEqual(recipient1.clients.map(\.client), [client1.clientId])

        guard let recipient2 = otrMessage.recipients.first(where: { $0.user == user2.userId }) else {
            return XCTFail("Expected user2 to be recipient")
        }

        XCTAssertEqual(recipient2.clients.map(\.client), [client2.clientId])
    }

    func testThatItDoesNotTargetCallMessagesIfNoTargetClientsAreSpecified() {
        // Given
        let selfClient = createSelfClient()

        // One user with two clients connected to self
        let user1 = ZMUser.insertNewObject(in: syncMOC)
        user1.remoteIdentifier = .create()

        let client1 = createClient(for: user1, connectedTo: selfClient)
        let client2 = createClient(for: user1, connectedTo: selfClient)

        // Another user with two clients connected to self
        let user2 = ZMUser.insertNewObject(in: syncMOC)
        user2.remoteIdentifier = .create()

        let client3 = createClient(for: user2, connectedTo: selfClient)
        let client4 = createClient(for: user2, connectedTo: selfClient)

        // A conversation with both users and self
        let conversation = ZMConversation.insertNewObject(in: syncMOC)
        conversation.remoteIdentifier = .create()
        conversation.addParticipantsAndUpdateConversationState(users: Set(arrayLiteral: ZMUser.selfUser(in: syncMOC), user1, user2), role: nil)
        conversation.needsToBeUpdatedFromBackend = false

        syncMOC.saveOrRollback()

        var nextRequest: ZMTransportRequest?

        // When we schedule the message with no targets
        syncMOC.performGroupedBlock {
            self.sut.send(data: Data(), conversationId: conversation.remoteIdentifier!, targets: nil) { _ in }
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        syncMOC.performGroupedBlock {
            nextRequest = self.sut.nextRequest()
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        guard let request = nextRequest else { return XCTFail("Expected next request") }

        // Then we do not tell backend to ignore missing clients
        XCTAssertEqual(request.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/otr/messages")

        guard
            let data = request.binaryData,
            let otrMessage = try? NewOtrMessage(serializedData: data)
        else {
            return XCTFail("Expected OTR message")
        }

        // Then we send the message to all clients in the conversation
        XCTAssertEqual(otrMessage.recipients.count, 2)

        guard let recipient1 = otrMessage.recipients.first(where: { $0.user == user1.userId }) else {
            return XCTFail("Expected user1 to be recipient")
        }

        XCTAssertEqual(Set(recipient1.clients.map(\.client)), Set([client1, client2].map(\.clientId)))

        guard let recipient2 = otrMessage.recipients.first(where: { $0.user == user2.userId }) else {
            return XCTFail("Expected user2 to be recipient")
        }

        XCTAssertEqual(Set(recipient2.clients.map(\.client)), Set([client3, client4].map(\.clientId)))
    }

    @discardableResult
    private func createClient(for user: ZMUser, connectedTo userClient: UserClient) -> UserClient {
        let client = UserClient.insertNewObject(in: syncMOC)
        client.remoteIdentifier = NSString.createAlphanumerical() as String
        client.user = user

        XCTAssertTrue(userClient.establishSessionWithClient(client, usingPreKey: try! userClient.keysStore.lastPreKey()))

        return client
    }

}
