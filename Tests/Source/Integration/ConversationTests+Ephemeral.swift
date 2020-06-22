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

import Foundation


class ConversationTests_Ephemeral : ConversationTestsBase {
    
    var obfuscationTimer : ZMMessageDestructionTimer? {
        return userSession!.syncManagedObjectContext.zm_messageObfuscationTimer
    }
    
    var deletionTimer : ZMMessageDestructionTimer? {
        return userSession!.managedObjectContext.zm_messageDeletionTimer
    }
}

extension ConversationTests_Ephemeral {

    func testThatItCreatesAndSendsAnEphemeralMessage(){
        // given
        XCTAssert(login())
        
        let conversation = self.conversation(for: selfToUser1Conversation!)!
        self.userSession?.perform {
            _ = conversation.append(text: "Hello") as! ZMClientMessage
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))
        mockTransportSession?.resetReceivedRequests()
        
        // when
        conversation.messageDestructionTimeout = .local(100)
        var message : ZMClientMessage!
        self.userSession?.perform {
            message = conversation.append(text: "Hello") as? ZMClientMessage
            XCTAssertTrue(message.isEphemeral)
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))

        // then
        XCTAssertEqual(mockTransportSession?.receivedRequests().count, 1)
        XCTAssertEqual(message.deliveryState, ZMDeliveryState.sent)
        XCTAssertTrue(message.isEphemeral)
        XCTAssertEqual(obfuscationTimer?.runningTimersCount, 1)
        XCTAssertEqual(deletionTimer?.runningTimersCount, 0)
    }
    
    func testThatItCreatesAndSendsAnEphemeralImageMessage(){
        // given
        XCTAssert(login())
        
        let conversation = self.conversation(for: selfToUser1Conversation!)!
        self.userSession?.perform {
            _ = conversation.append(text: "Hello") as! ZMClientMessage
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))
        mockTransportSession?.resetReceivedRequests()
        
        // when
        conversation.messageDestructionTimeout = .local(100)
        var message : ZMAssetClientMessage!
        self.userSession?.perform {
            message = conversation.append(imageFromData: self.verySmallJPEGData()) as? ZMAssetClientMessage
            XCTAssertTrue(message.isEphemeral)
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))
        
        // then
        XCTAssertEqual(mockTransportSession?.receivedRequests().count, 2)
        XCTAssertEqual(message.deliveryState, ZMDeliveryState.sent)
        XCTAssertTrue(message.isEphemeral)
        XCTAssertEqual(obfuscationTimer?.runningTimersCount, 1)
        XCTAssertEqual(deletionTimer?.runningTimersCount, 0)
    }
    
    func testThatItDeletesAnEphemeralMessage(){
        // given
        XCTAssert(login())
        
        let conversation = self.conversation(for: selfToUser1Conversation!)!
        let messageCount = conversation.allMessages.count

        // insert ephemeral message
        conversation.messageDestructionTimeout = .local(0.1)
        var ephemeral : ZMClientMessage!
        self.userSession?.perform {
            ephemeral = conversation.append(text: "Hello") as? ZMClientMessage
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))
        spinMainQueue(withTimeout: 0.5)
        XCTAssertTrue(ephemeral.isObfuscated)
        XCTAssertEqual(conversation.allMessages.count, messageCount+1)

        // when
        // other client deletes ephemeral message
        let fromClient = user1?.clients.anyObject() as! MockUserClient
        let toClient = selfUser?.clients.anyObject() as! MockUserClient
        let deleteMessage = GenericMessage(content: MessageDelete(messageId: ephemeral.nonce!))
        
        mockTransportSession?.performRemoteChanges { session in
            do {
                self.selfToUser1Conversation?.encryptAndInsertData(from: fromClient, to: toClient, data: try deleteMessage.serializedData())
            } catch {
                XCTFail()
            }
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))
        
        // then
        XCTAssertNotEqual(ephemeral.visibleInConversation, conversation)
        XCTAssertEqual(ephemeral.hiddenInConversation, conversation)
        XCTAssertNil(ephemeral.sender)
        XCTAssertEqual(conversation.allMessages.count, messageCount)
    }
    
    func remotelyInsertEphemeralMessage(conversation: MockConversation) {
        let fromClient = user1?.clients.anyObject() as! MockUserClient
        let toClient = selfUser?.clients.anyObject() as! MockUserClient
        let genericMessage = GenericMessage(content: Text(content: "foo"), expiresAfter: 0.1)
        XCTAssertEqual(genericMessage.ephemeral.expireAfterMillis, 100)
        guard case .ephemeral? = genericMessage.content else {
            return XCTFail()
        }
        
        mockTransportSession?.performRemoteChanges { session in
            do {
                conversation.encryptAndInsertData(from: fromClient, to: toClient, data: try genericMessage.serializedData())
            } catch {
                XCTFail()
            }
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))
    }
    
    func testThatItSendsADeletionMessageForAnEphemeralMessageWhenTheTimerFinishes(){
        // given
        XCTAssert(login())
        
        let conversation = self.conversation(for: selfToUser1Conversation!)!
        let messageCount = conversation.allMessages.count

        // the other  user inserts an ephemeral message
        remotelyInsertEphemeralMessage(conversation: selfToUser1Conversation!)
        guard let ephemeral = conversation.lastMessage as? ZMClientMessage,
            let genMessage = ephemeral.underlyingMessage,
            case .ephemeral? = genMessage.content else {
                return XCTFail()
        }
        XCTAssertEqual(genMessage.ephemeral.expireAfterMillis, 100)
        XCTAssertEqual(conversation.allMessages.count, messageCount+1)
        mockTransportSession?.resetReceivedRequests()
        
        // when
        // we start the destruction timer
        self.userSession?.perform {
            ephemeral.startDestructionIfNeeded()
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))
        spinMainQueue(withTimeout:5.1) // We can't set isTesting and therefore have to wait 5sec at least :-/
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1)) // we have to wait until the request "made the roundtrip" to the backend

        // then
        XCTAssertEqual(mockTransportSession?.receivedRequests().count, 1)
        XCTAssertEqual(conversation.allMessages.count, messageCount)

        // the ephemeral message is hidden
        XCTAssertNotEqual(ephemeral.visibleInConversation, conversation)
        XCTAssertEqual(ephemeral.hiddenInConversation, conversation)
        XCTAssertNil(ephemeral.sender)

        guard let _ = conversation.hiddenMessages.first(where: {
            if let message = $0 as? ZMClientMessage,
                    let deleteMessage = message.underlyingMessage, deleteMessage.hasDeleted,
                deleteMessage.deleted.messageID == ephemeral.nonce!.transportString() {
                return true
            }
            else {
                return false
            }
        })
        else {
            return XCTFail()
        }
    }
    
    func testThatItSendsANotificationThatTheMessageWasObfuscatedWhenTheTimerRunsOut() {
        // given
        XCTAssert(login())
        
        let conversation = self.conversation(for: selfToUser1Conversation!)!
        
        // when
        conversation.messageDestructionTimeout = .local(1)
        var ephemeral : ZMClientMessage!
        self.userSession?.perform {
            ephemeral = conversation.append(text: "Hello") as? ZMClientMessage
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.1))

        let messageObserver = MessageChangeObserver(message: ephemeral)!
        spinMainQueue(withTimeout: 1.1)
        
        // then
        XCTAssertTrue(ephemeral.isObfuscated)
        guard let messageChangeInfo = messageObserver.notifications.firstObject  as? MessageChangeInfo else {
            return XCTFail()
        }
        XCTAssertTrue(messageChangeInfo.isObfuscatedChanged)

    }
    
}
