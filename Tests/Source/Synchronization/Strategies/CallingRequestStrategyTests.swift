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
@testable import WireSyncEngine

class CallingRequestStrategyTests: MessagingTest {

    var sut: CallingRequestStrategy!
    var mockApplicationStatus: MockApplicationStatus!
    var mockRegistrationDelegate: ClientRegistrationDelegate!
    var mockFetchUserClientsUseCase: MockFetchUserClientsUseCase!

    override func setUp() {
        super.setUp()
        mockApplicationStatus = MockApplicationStatus()
        mockApplicationStatus.mockSynchronizationState = .online
        mockRegistrationDelegate = MockClientRegistrationDelegate()
        mockFetchUserClientsUseCase = MockFetchUserClientsUseCase()
        sut = CallingRequestStrategy(
            managedObjectContext: syncMOC,
            applicationStatus: mockApplicationStatus,
            clientRegistrationDelegate: mockRegistrationDelegate,
            flowManager: FlowManagerMock(),
            callEventStatus: CallEventStatus(),
            fetchUserClientsUseCase: mockFetchUserClientsUseCase
        )
        sut.callCenter = WireCallCenterV3Mock(
            userId: .stub,
            clientId: UUID().transportString(),
            uiMOC: uiMOC,
            flowManager: FlowManagerMock(),
            transport: WireCallCenterTransportMock()
        )
    }

    override func tearDown() {
        sut = nil
        mockRegistrationDelegate = nil
        mockApplicationStatus = nil
        mockFetchUserClientsUseCase = nil
        APIVersion.isFederationEnabled = false
        super.tearDown()
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

        let request = sut.nextRequest(for: .v0)
        XCTAssertEqual(request?.path, "/calls/config/v2")

        // when
        let payload = [ "config": true ]
        request?.complete(with: ZMTransportResponse(payload: payload as ZMTransportData, httpStatus: 200, transportSessionError: nil, apiVersion: APIVersion.v0.rawValue))

        // then
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }

    func testThatItGeneratesOnlyOneCallConfigRequest() {

        // given
        sut.requestCallConfig { (_, _) in}
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        // when
        let request = sut.nextRequest(for: .v0)
        XCTAssertNotNil(request)

        // then
        let secondRequest = sut.nextRequest(for: .v0)
        XCTAssertNil(secondRequest)
    }

    func testThatItGeneratesCompressedCallConfigRequest() {

        // given
        sut.requestCallConfig { (_, _) in}
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        // when
        guard let request = sut.nextRequest(for: .v0) else { return XCTFail() }

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

        let request = sut.nextRequest(for: .v0)
        XCTAssertEqual(request?.path, "/calls/config/v2")

        // when
        let badPayload = [ "error": "not found" ]
        request?.complete(with: ZMTransportResponse(payload: badPayload as ZMTransportData, httpStatus: 412, transportSessionError: nil, apiVersion: APIVersion.v0.rawValue))

        // when
        let payload = [ "config": true ]
        request?.complete(with: ZMTransportResponse(payload: payload as ZMTransportData, httpStatus: 200, transportSessionError: nil, apiVersion: APIVersion.v0.rawValue))

        // then
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))

    }

    // MARK: - Client List

    func testThatItGeneratesClientListRequestAndCallsTheCompletionHandler_NotFederated() throws {
        // Given
        let selfClient = createSelfClient()

        // One user with two clients connected to self.
        let user1 = ZMUser.insertNewObject(in: syncMOC)
        user1.remoteIdentifier = .create()
        let client1 = createClient(for: user1, connectedTo: selfClient)
        let client2 = createClient(for: user1, connectedTo: selfClient)

        // Another user with two clients connected to self.
        let user2 = ZMUser.insertNewObject(in: syncMOC)
        user2.remoteIdentifier = .create()
        let client3 = createClient(for: user2, connectedTo: selfClient)
        let client4 = createClient(for: user2, connectedTo: selfClient)

        // A conversation with both users and self.
        let conversation = ZMConversation.insertNewObject(in: syncMOC)
        conversation.remoteIdentifier = .create()
        conversation.messageProtocol = .proteus
        conversation.addParticipantsAndUpdateConversationState(
            users: [ZMUser.selfUser(in: syncMOC), user1, user2],
            role: nil
        )

        conversation.needsToBeUpdatedFromBackend = false
        syncMOC.saveOrRollback()

        let payload = """
        {
            "missing": {
                "\(user1.remoteIdentifier.uuidString)": ["\(client1.remoteIdentifier!)", "\(client2.remoteIdentifier!)"],
                "\(user2.remoteIdentifier.uuidString)": ["\(client3.remoteIdentifier!)", "\(client4.remoteIdentifier!)"]
            }
        }
        """

        // Expectation
        let receivedClientList = expectation(description: "Received client list")

        let avsClient1 = try XCTUnwrap(AVSClient(userClient: client1))
        let avsClient2 = try XCTUnwrap(AVSClient(userClient: client2))
        let avsClient3 = try XCTUnwrap(AVSClient(userClient: client3))
        let avsClient4 = try XCTUnwrap(AVSClient(userClient: client4))

        // When
        let conversationID = try XCTUnwrap(conversation.avsIdentifier)
        sut.requestClientsList(conversationId: conversationID) { clients in
            // Then
            XCTAssertEqual(clients.count, 4)
            XCTAssertTrue(clients.contains(avsClient1))
            XCTAssertTrue(clients.contains(avsClient2))
            XCTAssertTrue(clients.contains(avsClient3))
            XCTAssertTrue(clients.contains(avsClient4))
            receivedClientList.fulfill()
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        let request = sut.nextRequest(for: .v0)
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/otr/messages")

        // When
        request?.complete(with: ZMTransportResponse(payload: payload as ZMTransportData, httpStatus: 412, transportSessionError: nil, apiVersion: APIVersion.v0.rawValue))

        // Then
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }

    func testThatItGeneratesClientListRequestAndCallsTheCompletionHandler_Federated() throws {
        // Given
        APIVersion.isFederationEnabled = true

        let selfClient = createSelfClient()

        // One user with two clients connected to self.
        let user1 = ZMUser.insertNewObject(in: syncMOC)
        user1.remoteIdentifier = .create()
        user1.domain = "foo.com"
        let client1 = createClient(for: user1, connectedTo: selfClient)
        let client2 = createClient(for: user1, connectedTo: selfClient)

        // Another user with two clients connected to self.
        let user2 = ZMUser.insertNewObject(in: syncMOC)
        user2.remoteIdentifier = .create()
        user2.domain = "bar.com"
        let client3 = createClient(for: user2, connectedTo: selfClient)
        let client4 = createClient(for: user2, connectedTo: selfClient)

        // A conversation with both users and self.
        let conversation = ZMConversation.insertNewObject(in: syncMOC)
        conversation.remoteIdentifier = .create()
        conversation.messageProtocol = .proteus
        conversation.addParticipantsAndUpdateConversationState(
            users: [ZMUser.selfUser(in: syncMOC), user1, user2],
            role: nil
        )

        conversation.needsToBeUpdatedFromBackend = false
        syncMOC.saveOrRollback()

        let payload = """
        {
            "missing": {
                "foo.com": {
                    "\(user1.remoteIdentifier.uuidString)": ["\(client1.remoteIdentifier!)", "\(client2.remoteIdentifier!)"]
                },
                "bar.com": {
                    "\(user2.remoteIdentifier.uuidString)": ["\(client3.remoteIdentifier!)", "\(client4.remoteIdentifier!)"]
                }
            }
        }
        """

        // Expectation
        let receivedClientList = expectation(description: "Received client list")

        let avsClient1 = try XCTUnwrap(AVSClient(userClient: client1))
        let avsClient2 = try XCTUnwrap(AVSClient(userClient: client2))
        let avsClient3 = try XCTUnwrap(AVSClient(userClient: client3))
        let avsClient4 = try XCTUnwrap(AVSClient(userClient: client4))

        // When
        let conversationID = try XCTUnwrap(conversation.avsIdentifier)
        sut.requestClientsList(conversationId: conversationID) { clients in
            // Then
            XCTAssertEqual(clients.count, 4)
            XCTAssertTrue(clients.contains(avsClient1))
            XCTAssertTrue(clients.contains(avsClient2))
            XCTAssertTrue(clients.contains(avsClient3))
            XCTAssertTrue(clients.contains(avsClient4))
            receivedClientList.fulfill()
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        let request = sut.nextRequest(for: .v1)
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.apiVersion, APIVersion.v1.rawValue)
        XCTAssertEqual(request?.path, "/v1/conversations/foo.com/\(conversation.remoteIdentifier!.transportString())/proteus/messages")

        // When
        request?.complete(with: ZMTransportResponse(payload: payload as ZMTransportData, httpStatus: 412, transportSessionError: nil, apiVersion: APIVersion.v1.rawValue))

        // Then
        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))

    }

    func testThatItGeneratesClientListRequestAndCallsTheCompletionHandler_MLS() throws {
        // Given
        let selfClient = createSelfClient()

        // One user with two clients connected to self.
        let user1 = ZMUser.insertNewObject(in: syncMOC)
        user1.remoteIdentifier = .create()
        user1.domain = "foo.com"
        let client1 = createClient(for: user1, connectedTo: selfClient)
        let client2 = createClient(for: user1, connectedTo: selfClient)

        // Another user with two clients connected to self.
        let user2 = ZMUser.insertNewObject(in: syncMOC)
        user2.remoteIdentifier = .create()
        user2.domain = "bar.com"
        let client3 = createClient(for: user2, connectedTo: selfClient)
        let client4 = createClient(for: user2, connectedTo: selfClient)

        // An mls conversation with both users and self.
        let conversation = ZMConversation.insertNewObject(in: syncMOC)
        conversation.remoteIdentifier = .create()
        conversation.mlsGroupID = MLSGroupID([1, 2, 3])
        conversation.messageProtocol = .mls
        conversation.addParticipantsAndUpdateConversationState(
            users: [ZMUser.selfUser(in: syncMOC), user1, user2],
            role: nil
        )

        conversation.needsToBeUpdatedFromBackend = false
        syncMOC.saveOrRollback()

        // Expectations
        let receivedClientList = expectation(description: "Received client list")

        let avsClient1 = try XCTUnwrap(AVSClient(userClient: client1))
        let avsClient2 = try XCTUnwrap(AVSClient(userClient: client2))
        let avsClient3 = try XCTUnwrap(AVSClient(userClient: client3))
        let avsClient4 = try XCTUnwrap(AVSClient(userClient: client4))

        // Mock
        mockFetchUserClientsUseCase.mockReturnValueForFetchUserClients = Set([
            QualifiedClientID(
                userID: avsClient1.avsIdentifier.identifier,
                domain: "foo.com",
                clientID: avsClient1.clientId
            ),
            QualifiedClientID(
                userID: avsClient2.avsIdentifier.identifier,
                domain: "foo.com",
                clientID: avsClient2.clientId
            ),
            QualifiedClientID(
                userID: avsClient3.avsIdentifier.identifier,
                domain: "bar.com",
                clientID: avsClient3.clientId
            ),
            QualifiedClientID(
                userID: avsClient4.avsIdentifier.identifier,
                domain: "bar.com",
                clientID: avsClient4.clientId
            )
        ])

        // When
        let conversationID = try XCTUnwrap(conversation.avsIdentifier)
        sut.requestClientsList(conversationId: conversationID) { clients in
            // Then
            XCTAssertEqual(clients.count, 4)
            XCTAssertTrue(clients.contains(avsClient1))
            XCTAssertTrue(clients.contains(avsClient2))
            XCTAssertTrue(clients.contains(avsClient3))
            XCTAssertTrue(clients.contains(avsClient4))
            receivedClientList.fulfill()
        }

        XCTAssertTrue(waitForCustomExpectations(withTimeout: 0.5))
    }

    func testThatItGeneratesOnlyOneClientListRequest() throws {
        // Given
        let selfClient = createSelfClient()

        // One user with two clients connected to self.
        let user1 = ZMUser.insertNewObject(in: syncMOC)
        user1.remoteIdentifier = .create()
        createClient(for: user1, connectedTo: selfClient)
        createClient(for: user1, connectedTo: selfClient)

        // A conversation with both users and self.
        let conversation = ZMConversation.insertNewObject(in: syncMOC)
        conversation.remoteIdentifier = .create()
        conversation.messageProtocol = .proteus
        conversation.addParticipantsAndUpdateConversationState(
            users: [ZMUser.selfUser(in: syncMOC), user1],
            role: nil
        )

        conversation.needsToBeUpdatedFromBackend = false
        syncMOC.saveOrRollback()

        // When
        let conversationID = try XCTUnwrap(conversation.avsIdentifier)
        sut.requestClientsList(conversationId: conversationID) { _ in }
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        // Then
        let request = sut.nextRequest(for: .v0)
        XCTAssertNotNil(request)

        let secondRequest = sut.nextRequest(for: .v0)
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
        conversation.addParticipantsAndUpdateConversationState(users: [ZMUser.selfUser(in: syncMOC), user1, user2], role: nil)
        conversation.needsToBeUpdatedFromBackend = false

        syncMOC.saveOrRollback()

        // Targeting two specific clients
        let avsClient1 = AVSClient(userId: user1.avsIdentifier, clientId: client1.remoteIdentifier!)
        let avsClient2 = AVSClient(userId: user2.avsIdentifier, clientId: client2.remoteIdentifier!)
        let targets = [avsClient1, avsClient2]

        var nextRequest: ZMTransportRequest?

        // When we schedule the targeted message
        syncMOC.performGroupedBlock {
            self.sut.send(data: Data(), conversationId: conversation.avsIdentifier!, targets: targets) { _ in }
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        syncMOC.performGroupedBlock {
            nextRequest = self.sut.nextRequest(for: .v0)
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        guard let request = nextRequest else { return XCTFail("Expected next request") }

        // Then we tell backend to ignore missing clients (the non targeted conversation participants)
        XCTAssertEqual(request.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/otr/messages?ignore_missing=true")

        guard
            let data = request.binaryData,
            let otrMessage = try? Proteus_NewOtrMessage(serializedData: data)
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
        conversation.addParticipantsAndUpdateConversationState(users: [ZMUser.selfUser(in: syncMOC), user1, user2], role: nil)
        conversation.needsToBeUpdatedFromBackend = false

        syncMOC.saveOrRollback()

        var nextRequest: ZMTransportRequest?

        // When we schedule the message with no targets
        syncMOC.performGroupedBlock {
            self.sut.send(data: Data(), conversationId: conversation.avsIdentifier!, targets: nil) { _ in }
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        syncMOC.performGroupedBlock {
            nextRequest = self.sut.nextRequest(for: .v0)
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        guard let request = nextRequest else { return XCTFail("Expected next request") }

        // Then we do not tell backend to ignore missing clients
        XCTAssertEqual(request.path, "/conversations/\(conversation.remoteIdentifier!.transportString())/otr/messages")

        guard
            let data = request.binaryData,
            let otrMessage = try? Proteus_NewOtrMessage(serializedData: data)
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

    // MARK: - MLS messages

    // Note: at the moment, all mls messages are sent to every participant in the group.
    // When we implement subgroups, then we may be able to assert who the recipients are.

    func test_ThatItSendsMLSConfStartMessage_ToAllParticipants_WhenNoTargetRecipientsAreSpecified() {
        // Given
        let selfClient = createSelfClient()

        // One user with two clients connected to self
        let user1 = ZMUser.insertNewObject(in: syncMOC)
        user1.remoteIdentifier = .create()

        _ = createClient(for: user1, connectedTo: selfClient)
        _ = createClient(for: user1, connectedTo: selfClient)

        // Another user with two clients connected to self
        let user2 = ZMUser.insertNewObject(in: syncMOC)
        user2.remoteIdentifier = .create()

        _ = createClient(for: user2, connectedTo: selfClient)
        _ = createClient(for: user2, connectedTo: selfClient)

        // An MLS conversation with both users and self
        let conversation = ZMConversation.insertNewObject(in: syncMOC)
        conversation.remoteIdentifier = .create()
        conversation.mlsGroupID = MLSGroupID(Data([1, 2, 3]))
        conversation.messageProtocol = .mls
        conversation.addParticipantsAndUpdateConversationState(users: [ZMUser.selfUser(in: syncMOC), user1, user2], role: nil)
        conversation.needsToBeUpdatedFromBackend = false

        syncMOC.saveOrRollback()

        let mockMLSController = MockMLSController()

        syncMOC.performGroupedBlock {
            self.syncMOC.test_setMockMLSController(mockMLSController)
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        var nextRequest: ZMTransportRequest?

        // When we schedule the message with no targets
        syncMOC.performGroupedBlock {
            self.sut.send(data: self.callMessage(withType: "CONFSTART"), conversationId: conversation.avsIdentifier!, targets: nil) { _ in }
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        syncMOC.performGroupedBlock {
            nextRequest = self.sut.nextRequest(for: .v2)
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        guard let request = nextRequest else { return XCTFail("Expected next request") }

        // Then it's an mls request
        XCTAssertEqual(request.path, "/v2/mls/messages")
        XCTAssertEqual(request.method, .methodPOST)
    }

    // Note: at the moment, all mls messages are sent to every participant in the group.
    // When we implement subgroups, then we may be able to assert who the recipients are.

    func test_ThatItSendsMLSConfKeyMessage_ToAllParticipants_EvenIfTargetRecipientsAreSpecified() {
        // Given
        let selfClient = createSelfClient()

        // One user with two clients connected to self
        let user1 = ZMUser.insertNewObject(in: syncMOC)
        user1.remoteIdentifier = .create()

        let client1 = createClient(for: user1, connectedTo: selfClient)
        _ = createClient(for: user1, connectedTo: selfClient)

        // Another user with two clients connected to self
        let user2 = ZMUser.insertNewObject(in: syncMOC)
        user2.remoteIdentifier = .create()

        let client3 = createClient(for: user2, connectedTo: selfClient)
        _ = createClient(for: user2, connectedTo: selfClient)

        // Targeting two specific clients
        let avsClient1 = AVSClient(userId: user1.avsIdentifier, clientId: client1.remoteIdentifier!)
        let avsClient2 = AVSClient(userId: user2.avsIdentifier, clientId: client3.remoteIdentifier!)
        let targets = [avsClient1, avsClient2]

        // An MLS conversation with both users and self
        let conversation = ZMConversation.insertNewObject(in: syncMOC)
        conversation.remoteIdentifier = .create()
        conversation.mlsGroupID = MLSGroupID(Data([1, 2, 3]))
        conversation.messageProtocol = .mls
        conversation.addParticipantsAndUpdateConversationState(users: [ZMUser.selfUser(in: syncMOC), user1, user2], role: nil)
        conversation.needsToBeUpdatedFromBackend = false

        syncMOC.saveOrRollback()

        let mockMLSController = MockMLSController()

        syncMOC.performGroupedBlock {
            self.syncMOC.test_setMockMLSController(mockMLSController)
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        var nextRequest: ZMTransportRequest?

        // When we schedule the message
        syncMOC.performGroupedBlock {
            self.sut.send(data: self.callMessage(withType: "CONFKEY"), conversationId: conversation.avsIdentifier!, targets: targets) { _ in }
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        syncMOC.performGroupedBlock {
            nextRequest = self.sut.nextRequest(for: .v2)
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        guard let request = nextRequest else { return XCTFail("Expected next request") }

        // Then it's an mls request
        XCTAssertEqual(request.path, "/v2/mls/messages")
        XCTAssertEqual(request.method, .methodPOST)
    }

    // Note: when we implement subgroups, we'll be able to target reject messages, and
    // then we'll replace this test.

    func test_ThatItIgnoresMLSRejectMessage() {
        // Given
        let selfClient = createSelfClient()

        let user1 = ZMUser.insertNewObject(in: syncMOC)
        user1.remoteIdentifier = .create()
        let client1 = createClient(for: user1, connectedTo: selfClient)

        let user2 = ZMUser.insertNewObject(in: syncMOC)
        user2.remoteIdentifier = .create()
        _ = createClient(for: user2, connectedTo: selfClient)

        // An MLS conversation with both users and self
        let conversation = ZMConversation.insertNewObject(in: syncMOC)
        conversation.remoteIdentifier = .create()
        conversation.mlsGroupID = MLSGroupID(Data([1, 2, 3]))
        conversation.messageProtocol = .mls
        conversation.addParticipantsAndUpdateConversationState(users: [ZMUser.selfUser(in: syncMOC), user1, user2], role: nil)
        conversation.needsToBeUpdatedFromBackend = false

        syncMOC.saveOrRollback()

        let mockMLSController = MockMLSController()

        syncMOC.performGroupedBlock {
            self.syncMOC.test_setMockMLSController(mockMLSController)
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        var nextRequest: ZMTransportRequest?

        // Targeting one client
        let avsClient1 = AVSClient(userId: user1.avsIdentifier, clientId: client1.remoteIdentifier!)
        let targets = [avsClient1]

        // When we schedule the message
        syncMOC.performGroupedBlock {
            self.sut.send(data: self.callMessage(withType: "REJECT"), conversationId: conversation.avsIdentifier!, targets: targets) { _ in }
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        syncMOC.performGroupedBlock {
            nextRequest = self.sut.nextRequest(for: .v2)
        }

        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        // Then no request is made
        XCTAssertNil(nextRequest)
    }

    private func callMessage(withType type: String) -> Data {
        let json = [
            "src_userid": UUID.create().uuidString,
            "src_clientid": "clientID",
            "resp": false,
            "type": type
        ] as [String: Any]

        return try! JSONSerialization.data(withJSONObject: json, options: [])
    }

    // MARK: - Event processing

    func testThatItAsksCallCenterToMute_WhenReceivingRemoteMuteEvent() {
        // GIVEN
        let json = ["src_userid": UUID.create().uuidString,
                    "src_clientid": "clientID",
                    "resp": false,
                    "type": "REMOTEMUTE"] as [String: Any]
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        let content = String(data: data, encoding: .utf8)!
        let message = GenericMessage(content: Calling(content: content))
        let text = try? message.serializedData().base64String()
        let payload = [
            "conversation": UUID().transportString(),
            "data": [
                "sender": UUID().transportString(),
                "text": text
            ],
            "from": UUID().transportString(),
            "time": Date().transportString(),
            "type": "conversation.otr-message-add"
        ] as [String: Any]

        let updateEvent = ZMUpdateEvent(fromEventStreamPayload: payload as ZMTransportData, uuid: UUID())!

        sut.callCenter?.muted = false

        // WHEN
        sut.processEventsWhileInBackground([updateEvent])

        // THEN
        XCTAssertTrue(sut.callCenter?.muted ?? false)
    }

}

class MockMLSController: MLSControllerProtocol {

    func uploadKeyPackagesIfNeeded() {
        fatalError("not implemented")
    }

    func createGroup(for groupID: MLSGroupID) throws {
        fatalError("not implemented")
    }

    func conversationExists(groupID: MLSGroupID) -> Bool {
        fatalError("not implemented")
    }

    func processWelcomeMessage(welcomeMessage: String) throws -> MLSGroupID {
        fatalError("not implemented")
    }

    func encrypt(message: Bytes, for groupID: MLSGroupID) throws -> Bytes {
        return message
    }

    func decrypt(message: String, for groupID: MLSGroupID) throws -> Data? {
        fatalError("not implemented")
    }

    func addMembersToConversation(with users: [MLSUser], for groupID: MLSGroupID) async throws {
        fatalError("not implemented")
    }

    func removeMembersFromConversation(with clientIds: [MLSClientID], for groupID: MLSGroupID) async throws {
        fatalError("not implemented")
    }

}

class MockFetchUserClientsUseCase: FetchUserClientsUseCaseProtocol {

    var mockReturnValueForFetchUserClients = Set<QualifiedClientID>()
    var mockErrorForFetchUserClients: Error?

    func fetchUserClients(
        userIDs: Set<QualifiedID>,
        in context: NSManagedObjectContext
    ) async throws -> Set<QualifiedClientID> {
        if let error = mockErrorForFetchUserClients {
            throw error
        } else {
            return mockReturnValueForFetchUserClients
        }
    }
}
