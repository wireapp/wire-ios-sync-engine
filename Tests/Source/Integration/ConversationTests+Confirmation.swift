//
// Wire
// Copyright (C) 2016 Wire Swiss GmbH
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

class ConversationTests_Confirmation: ConversationTestsBase {

    func testThatItSendsAConfirmationWhenReceivingAMessageInAOneOnOneConversation() {
        // given
        XCTAssertTrue(logInAndWaitForSyncToBeComplete())
        
        let fromClient = user1.clients.anyObject() as! MockUserClient
        let toClient = selfUser.clients.anyObject() as! MockUserClient
        let textMessage = ZMGenericMessage(text: "Hello", nonce: NSUUID.createUUID().transportString())
        let conversation = conversationForMockConversation(selfToUser1Conversation)

        let requestPath = "/conversations/\(conversation.remoteIdentifier.transportString())/otr/messages"
        
        // expect
        mockTransportSession.responseGeneratorBlock = { request in
            if (request.path == requestPath) {
                guard let hiddenMessage = conversation.hiddenMessages.lastObject as? ZMClientMessage,
                      let message = conversation.messages.lastObject as? ZMClientMessage
                else {
                    XCTFail("Did not insert confirmation message.")
                    return nil
                }
                XCTAssertTrue(hiddenMessage.genericMessage!.hasConfirmation())
                XCTAssertEqual(hiddenMessage.genericMessage!.confirmation.messageId, message.nonce.transportString())
            }
            return nil
        }
        
        // when
        mockTransportSession.performRemoteChanges { session in
            self.selfToUser1Conversation.encryptAndInsertDataFromClient(fromClient, toClient: toClient, data: textMessage.data())
        }
        XCTAssertTrue(waitForEverythingToBeDone())
        
        // then
        let messages = conversation.messages
        XCTAssertEqual(messages.count, 2) // system message & inserted message
        
        guard let request = mockTransportSession.receivedRequests().last else {return XCTFail()}
        XCTAssertEqual(request.path, requestPath)
        
        XCTAssertEqual(conversation.lastModifiedDate, (messages.lastObject as! ZMClientMessage).serverTimestamp)
    }
    
    
    func testThatItSetsAMessageToDeliveredWhenReceivingAConfirmationMessageInAOneOnOneConversation() {
        // given
        XCTAssertTrue(logInAndWaitForSyncToBeComplete())
        
        let conversation = conversationForMockConversation(selfToUser1Conversation)
        var message : ZMClientMessage!
        self.userSession.performChanges{
            message = conversation.appendMessageWithText("Hello") as! ZMClientMessage
        }
        XCTAssertTrue(waitForEverythingToBeDone())
        XCTAssertEqual(message.deliveryState, ZMDeliveryState.Sent)

        let fromClient = user1.clients.anyObject() as! MockUserClient
        let toClient = selfUser.clients.anyObject() as! MockUserClient
        let confirmationMessage = ZMGenericMessage(confirmation: message.nonce.transportString(), type: .DELIVERED, nonce:NSUUID.createUUID().transportString())
        
        // when
        mockTransportSession.performRemoteChanges { session in
            self.selfToUser1Conversation.encryptAndInsertDataFromClient(fromClient, toClient: toClient, data: confirmationMessage.data())
        }
        XCTAssertTrue(waitForEverythingToBeDone())
        
        // then
        // The confirmation message is not inserted
        XCTAssertEqual(conversation.hiddenMessages.count, 0)
        XCTAssertEqual(message.deliveryState, ZMDeliveryState.Delivered)
        
        XCTAssertEqual(conversation.lastModifiedDate, message.serverTimestamp)
    }
    
    func testThatItSendsANotificationWhenUpdatingTheDeliveryState() {
        // given
        XCTAssertTrue(logInAndWaitForSyncToBeComplete())
        
        let conversation = conversationForMockConversation(selfToUser1Conversation)
        var message : ZMClientMessage!
        self.userSession.performChanges{
            message = conversation.appendMessageWithText("Hello") as! ZMClientMessage
        }
        XCTAssertTrue(waitForEverythingToBeDone())
        XCTAssertEqual(conversation.hiddenMessages.count, 0)
        XCTAssertEqual(message.deliveryState, ZMDeliveryState.Sent)
        
        let fromClient = user1.clients.anyObject() as! MockUserClient
        let toClient = selfUser.clients.anyObject() as! MockUserClient
        let confirmationMessage = ZMGenericMessage(confirmation: message.nonce.transportString(), type: .DELIVERED, nonce:NSUUID.createUUID().transportString())
        
        let convObserver = ConversationChangeObserver(conversation: conversation)
        let messageObserver = MessageChangeObserver(message: message)
        defer {
            convObserver.tearDown()
            messageObserver.tearDown()
        }

        // when
        mockTransportSession.performRemoteChanges { session in
            self.selfToUser1Conversation.encryptAndInsertDataFromClient(fromClient, toClient: toClient, data: confirmationMessage.data())
        }
        XCTAssertTrue(waitForEverythingToBeDone())
        
        // then
        if convObserver.notifications.count > 0 {
            return XCTFail()
        }
        guard let messageChangeInfo = messageObserver.notifications.firstObject  as? MessageChangeInfo else {
            return XCTFail()
        }
        XCTAssertTrue(messageChangeInfo.deliveryStateChanged)
    }
}
