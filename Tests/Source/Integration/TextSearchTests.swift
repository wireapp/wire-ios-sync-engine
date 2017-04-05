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


import XCTest
import WireTesting


fileprivate class MockSearchDelegate: TextSearchQueryDelegate {
    var results = [TextQueryResult]()

    func textSearchQueryDidReceive(result: TextQueryResult) {
        results.append(result)
    }
}


class TextSearchTests: ConversationTestsBase {

    func testThatItFindsAMessageSendRemotely() {
        // Given
        XCTAssertTrue(logInAndWaitForSyncToBeComplete())

        let firstClient = user1.clients.anyObject() as! MockUserClient
        let selfClient = selfUser.clients.anyObject() as! MockUserClient

        // When
        mockTransportSession.performRemoteChanges { session in
            let genericMessage = ZMGenericMessage.message(text: "Hello there!", nonce: UUID.create().transportString())
            self.selfToUser1Conversation.encryptAndInsertData(from: firstClient, to: selfClient, data: genericMessage.data())
        }

        XCTAssert(waitForEverythingToBeDone())

        guard let convo = conversation(for: selfToUser1Conversation) else { return XCTFail("Undable to get conversation") }
        let lastMessage = convo.messages.lastObject as? ZMMessage
        XCTAssertEqual(lastMessage?.textMessageData?.messageText, "Hello there!")

        // Then
        verifyThatItCanSearch(for: "There", in: convo, andFinds: lastMessage)
    }

    func testThatItFindsAMessageEditedRemotely() {
        // Given
        XCTAssertTrue(logInAndWaitForSyncToBeComplete())

        let firstClient = user1.clients.anyObject() as! MockUserClient
        let selfClient = selfUser.clients.anyObject() as! MockUserClient
        let nonce = UUID.create().transportString()

        // When
        mockTransportSession.performRemoteChanges { _ in
            let genericMessage = ZMGenericMessage.message(text: "Hello there!", nonce: nonce)
            self.selfToUser1Conversation.encryptAndInsertData(from: firstClient, to: selfClient, data: genericMessage.data())
        }

        XCTAssert(waitForEverythingToBeDone())

        guard let convo = conversation(for: selfToUser1Conversation) else { return XCTFail("Undable to get conversation") }
        guard let lastMessage = convo.messages.lastObject as? ZMMessage else { return XCTFail("Undable to get message") }
        XCTAssertEqual(lastMessage.textMessageData?.messageText, "Hello there!")

        // And when
        mockTransportSession.performRemoteChanges { _ in
            let genericMessage = ZMGenericMessage(editMessage: nonce, newText: "This is an edit!!", nonce: UUID.create().transportString())
            self.selfToUser1Conversation.encryptAndInsertData(from: firstClient, to: selfClient, data: genericMessage.data())
        }

        XCTAssert(waitForEverythingToBeDone())
        guard let editedMessage = convo.messages.lastObject as? ZMMessage else { return XCTFail("Undable to get message") }
        XCTAssertEqual(editedMessage.textMessageData?.messageText, "This is an edit!!")

        // Then
        verifyThatItCanSearch(for: "edit", in: convo, andFinds: editedMessage)
        verifyThatItCanSearch(for: "Hello", in: convo, andFinds: nil)
    }

    func testThatItDoesNotFindAnEphemeralMessageSentRemotely() {
        // Given
        XCTAssertTrue(logInAndWaitForSyncToBeComplete())

        let firstClient = user1.clients.anyObject() as! MockUserClient
        let selfClient = selfUser.clients.anyObject() as! MockUserClient
        let text = "This is an ephemeral message"

        // When
        mockTransportSession.performRemoteChanges { session in
            let genericMessage = ZMGenericMessage.genericMessage(
                pbMessage: ZMText(message: text, linkPreview: nil)!,
                messageID: UUID.create().transportString(),
                expiresAfter: NSNumber(value: 300)
            )
            self.selfToUser1Conversation.encryptAndInsertData(from: firstClient, to: selfClient, data: genericMessage.data())
        }

        XCTAssert(waitForEverythingToBeDone())

        guard let convo = conversation(for: selfToUser1Conversation) else { return XCTFail("Undable to get conversation") }
        let lastMessage = convo.messages.lastObject as? ZMMessage
        XCTAssertEqual(lastMessage?.textMessageData?.messageText, text)

        // Then
        verifyThatItCanSearch(for: "ephemeral", in: convo, andFinds: nil)
    }

    func testThatItDoesNotFindAMessageDeletedRemotely() {
        // Given
        XCTAssertTrue(logInAndWaitForSyncToBeComplete())

        let firstClient = user1.clients.anyObject() as! MockUserClient
        let selfClient = selfUser.clients.anyObject() as! MockUserClient
        let nonce = UUID.create().transportString()

        // When
        mockTransportSession.performRemoteChanges { session in
            let genericMessage = ZMGenericMessage.message(text: "Hello there!", nonce: nonce)
            self.selfToUser1Conversation.encryptAndInsertData(from: firstClient, to: selfClient, data: genericMessage.data())
        }

        XCTAssert(waitForEverythingToBeDone())

        guard let convo = conversation(for: selfToUser1Conversation) else { return XCTFail("Undable to get conversation") }
        let lastMessage = convo.messages.lastObject as? ZMMessage
        XCTAssertEqual(lastMessage?.textMessageData?.messageText, "Hello there!")

        // Then
        verifyThatItCanSearch(for: "Hello", in: convo, andFinds: lastMessage)

        // And when
        mockTransportSession.performRemoteChanges { _ in
            let genericMessage = ZMGenericMessage(deleteMessage: nonce, nonce:UUID.create().transportString())
            self.selfToUser1Conversation.encryptAndInsertData(from: firstClient, to: selfClient, data: genericMessage.data())
        }

        // Then
        verifyThatItCanSearch(for: "Hello", in: convo, andFinds: nil)
    }

    func verifyThatItCanSearch(for query: String, in conversation: ZMConversation, andFinds message: ZMMessage?, file: StaticString = #file, line: UInt = #line) {
        // Given
        let delegate = MockSearchDelegate()
        let searchQuery = TextSearchQuery(conversation: conversation, query: query, delegate: delegate)

        // When
        searchQuery?.execute()
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5), file: file, line: line)

        // Then
        guard let result = delegate.results.last else { return XCTFail("No search result found", file: file, line: line) }

        if let message = message {
            XCTAssertEqual(result.matches.count, 1, file: file, line: line)
            guard let match = result.matches.first else { return XCTFail("No match found", file: file, line: line) }
            XCTAssertEqual(match.textMessageData?.messageText, message.textMessageData?.messageText, file: file, line: line)
        } else {
            XCTAssert(result.matches.isEmpty, file: file, line: line)
        }
    }

}
