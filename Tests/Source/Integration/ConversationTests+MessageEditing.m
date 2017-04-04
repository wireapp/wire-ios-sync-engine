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


@import WireTesting;
@import WireDataModel;

#import "ConversationTestsBase.h"
#import "NotificationObservers.h"

@interface ConversationTests_MessageEditing : ConversationTestsBase

@end



@implementation ConversationTests_MessageEditing

#pragma mark - Sending

- (void)testThatItSendsOutARequestToEditAMessage
{
    // given
    XCTAssert([self logInAndWaitForSyncToBeComplete]);
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    __block ZMMessage *message;
    [self.userSession performChanges:^{
        message = (id)[conversation appendMessageWithText:@"Foo"];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    NSUInteger messageCount = conversation.messages.count;
    [self.mockTransportSession resetReceivedRequests];
    
    // when
    __block ZMMessage *editMessage;
    [self.userSession performChanges:^{
        editMessage = [ZMMessage edit:message newText:@"Bar"];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(conversation.messages.count, messageCount);
    XCTAssertEqualObjects(conversation.messages.lastObject, editMessage);
    XCTAssertEqualObjects(editMessage.textMessageData.messageText, @"Bar");
    XCTAssertNotEqualObjects(editMessage.nonce, message.nonce);

    XCTAssertEqual(self.mockTransportSession.receivedRequests.count, 1u);
    ZMTransportRequest *request = self.mockTransportSession.receivedRequests.lastObject;
    NSString *expectedPath = [NSString stringWithFormat:@"/conversations/%@/otr/messages", conversation.remoteIdentifier.transportString];
    XCTAssertEqualObjects(request.path, expectedPath);
    XCTAssertEqual(request.method, ZMMethodPOST);
}

- (void)testThatItInsertsNewMessageAtSameIndexAsOriginalMessage
{
    // given
    XCTAssert([self logInAndWaitForSyncToBeComplete]);
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    __block ZMMessage *message;
    [self.userSession performChanges:^{
        message = (id)[conversation appendMessageWithText:@"Foo"];
        [self spinMainQueueWithTimeout:0.1];
        [conversation appendMessageWithText:@"Fa"];
        [self spinMainQueueWithTimeout:0.1];
        [conversation appendMessageWithText:@"Fa"];
        [self spinMainQueueWithTimeout:0.1];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    id convToken = [ConversationChangeInfo addObserver:self.conversationChangeObserver forConversation:conversation];
    [self.conversationChangeObserver clearNotifications];
    
    ZMConversationMessageWindow *window = [conversation conversationWindowWithSize:10];
    MessageWindowChangeObserver *windowObserver = [[MessageWindowChangeObserver alloc] initWithMessageWindow:window];
    NSUInteger messageIndex = [window.messages indexOfObject:message];
    XCTAssertEqual(messageIndex, 2u);
    
    // when
    __block ZMMessage *editMessage;
    [self.userSession performChanges:^{
        editMessage = [ZMMessage edit:message newText:@"Bar"];
    }];
    WaitForAllGroupsToBeEmpty(0.5);

    // then
    NSUInteger editedMessageIndex = [window.messages indexOfObject:editMessage];
    XCTAssertEqual(editedMessageIndex, messageIndex);
    
    XCTAssertEqual(self.conversationChangeObserver.notifications.count, 1u);
    ConversationChangeInfo *convInfo =  self.conversationChangeObserver.notifications.firstObject;
    XCTAssertTrue(convInfo.messagesChanged);
    XCTAssertFalse(convInfo.participantsChanged);
    XCTAssertFalse(convInfo.nameChanged);
    XCTAssertFalse(convInfo.unreadCountChanged);
    XCTAssertTrue(convInfo.lastModifiedDateChanged);
    XCTAssertFalse(convInfo.connectionStateChanged);
    XCTAssertFalse(convInfo.isSilencedChanged);
    XCTAssertFalse(convInfo.conversationListIndicatorChanged);
    XCTAssertFalse(convInfo.clearedChanged);
    XCTAssertFalse(convInfo.securityLevelChanged);
    
    XCTAssertEqual(windowObserver.notifications.count, 2u);
    // Replacing the edited message with a new message
    MessageWindowChangeInfo *windowInfo1 = windowObserver.notifications.firstObject;
    XCTAssertEqualObjects(windowInfo1.deletedIndexes, [NSIndexSet indexSetWithIndex:messageIndex]);
    XCTAssertEqualObjects(windowInfo1.insertedIndexes, [NSIndexSet indexSetWithIndex:messageIndex]);
    XCTAssertEqualObjects(windowInfo1.updatedIndexes, [NSIndexSet indexSet]);
    XCTAssertEqualObjects(windowInfo1.movedIndexPairs, @[]);
    
    // Sending successfully (deliveryState changes)
    MessageWindowChangeInfo *windowInfo2 = windowObserver.notifications.lastObject;
    XCTAssertEqualObjects(windowInfo2.deletedIndexes, [NSIndexSet indexSet]);
    XCTAssertEqualObjects(windowInfo2.insertedIndexes, [NSIndexSet indexSet]);
    XCTAssertEqualObjects(windowInfo2.updatedIndexes, [NSIndexSet indexSetWithIndex:messageIndex]);
    XCTAssertEqualObjects(windowInfo2.movedIndexPairs, @[]);
    
    (void)convToken;
}

- (void)testThatItCanEditAnEditedMessage
{
    // given
    XCTAssert([self logInAndWaitForSyncToBeComplete]);
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    __block ZMMessage *message;
    [self.userSession performChanges:^{
        message = (id)[conversation appendMessageWithText:@"Foo"];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    __block ZMMessage *editMessage1;
    [self.userSession performChanges:^{
        editMessage1 = [ZMMessage edit:message newText:@"Bar"];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    NSUInteger messageCount = conversation.messages.count;
    [self.mockTransportSession resetReceivedRequests];
    
    // when
    __block ZMMessage *editMessage2;
    [self.userSession performChanges:^{
        editMessage2 = [ZMMessage edit:editMessage1 newText:@"FooBar"];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(conversation.messages.count, messageCount);
    XCTAssertEqualObjects(conversation.messages.lastObject, editMessage2);
    XCTAssertEqualObjects(editMessage2.textMessageData.messageText, @"FooBar");
    
    XCTAssertEqual(self.mockTransportSession.receivedRequests.count, 1u);
    ZMTransportRequest *request = self.mockTransportSession.receivedRequests.lastObject;
    NSString *expectedPath = [NSString stringWithFormat:@"/conversations/%@/otr/messages", conversation.remoteIdentifier.transportString];
    XCTAssertEqualObjects(request.path, expectedPath);
    XCTAssertEqual(request.method, ZMMethodPOST);
}

- (void)testThatItKeepsTheContentWhenMessageSendingFailsButOverwritesTheNonce
{
    // given
    XCTAssert([self logInAndWaitForSyncToBeComplete]);
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    __block ZMMessage *message;
    [self.userSession performChanges:^{
        message = (id)[conversation appendMessageWithText:@"Foo"];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    NSUInteger messageCount = conversation.messages.count;
    NSUUID *originalNonce = message.nonce;
    
    [self.mockTransportSession resetReceivedRequests];
    self.mockTransportSession.responseGeneratorBlock = ^ZMTransportResponse *(ZMTransportRequest *request){
        if ([request.path isEqualToString:[NSString stringWithFormat:@"/conversations/%@/otr/messages", conversation.remoteIdentifier.transportString]]) {
            return ResponseGenerator.ResponseNotCompleted;
        }
        return nil;
    };
    
    // when
    __block ZMMessage *editMessage;
    [self.userSession performChanges:^{
        editMessage = [ZMMessage edit:message newText:@"Bar"];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    [self.mockTransportSession expireAllBlockedRequests];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(conversation.messages.count, messageCount);
    XCTAssertTrue(message.isZombieObject);

    XCTAssertEqualObjects(conversation.messages.lastObject, editMessage);
    XCTAssertEqualObjects(editMessage.textMessageData.messageText, @"Bar");
    XCTAssertEqualObjects(editMessage.nonce, originalNonce);
}

- (void)testThatWhenResendingAFailedEditMessageItInsertsANewOne
{
    // given
    XCTAssert([self logInAndWaitForSyncToBeComplete]);
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    __block ZMMessage *message;
    [self.userSession performChanges:^{
        message = (id)[conversation appendMessageWithText:@"Foo"];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    NSUInteger messageCount = conversation.messages.count;
    NSUUID *originalNonce = message.nonce;
    
    [self.mockTransportSession resetReceivedRequests];
    self.mockTransportSession.responseGeneratorBlock = ^ZMTransportResponse *(ZMTransportRequest *request){
        if ([request.path isEqualToString:[NSString stringWithFormat:@"/conversations/%@/otr/messages", conversation.remoteIdentifier.transportString]]) {
            return ResponseGenerator.ResponseNotCompleted;
        }
        return nil;
    };
    
    __block ZMMessage *editMessage1;
    [self.userSession performChanges:^{
        editMessage1 = [ZMMessage edit:message newText:@"Bar"];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    [self.mockTransportSession expireAllBlockedRequests];
    WaitForAllGroupsToBeEmpty(0.5);
    self.mockTransportSession.responseGeneratorBlock = nil;
    
    // when
    [self.userSession performChanges:^{
        [editMessage1 resend];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(conversation.messages.count, messageCount);
    XCTAssertTrue(message.isZombieObject);
    
    ZMMessage *editMessage2 = conversation.messages.lastObject;
    XCTAssertNotEqual(editMessage1, editMessage2);
    
    // The failed edit message is hidden
    XCTAssertTrue(editMessage1.hasBeenDeleted);
    XCTAssertEqualObjects(editMessage1.nonce, originalNonce);

    // The new edit message has a new nonce and the same text
    XCTAssertEqualObjects(editMessage2.textMessageData.messageText, @"Bar");
    XCTAssertNotEqualObjects(editMessage2.nonce, originalNonce);
}


#pragma mark - Receiving

- (void)testThatItProcessesEditingMessages
{
    // given
    XCTAssert([self logInAndWaitForSyncToBeComplete]);
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    NSUInteger messageCount = conversation.messages.count;
    
    MockUserClient *fromClient = self.user1.clients.anyObject;
    MockUserClient *toClient = self.selfUser.clients.anyObject;
    ZMGenericMessage *textMessage = [ZMGenericMessage messageWithText:@"Foo" nonce:[NSUUID createUUID].transportString expiresAfter:nil];
    
    [self.mockTransportSession performRemoteChanges:^(id ZM_UNUSED session) {
        [self.selfToUser1Conversation encryptAndInsertDataFromClient:fromClient toClient:toClient data:textMessage.data];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    XCTAssertEqual(conversation.messages.count, messageCount+1);
    ZMClientMessage *receivedMessage = conversation.messages.lastObject;
    XCTAssertEqualObjects(receivedMessage.textMessageData.messageText, @"Foo");
    NSUUID *messageNone = receivedMessage.nonce;
    
    // when
    ZMGenericMessage *editMessage = [ZMGenericMessage messageWithEditMessage:messageNone.transportString  newText:@"Bar" nonce:[NSUUID createUUID].transportString];
    [self.mockTransportSession performRemoteChanges:^(id ZM_UNUSED session) {
        [self.selfToUser1Conversation encryptAndInsertDataFromClient:fromClient toClient:toClient data:editMessage.data];
    }];
    WaitForAllGroupsToBeEmpty(0.5);

    // then
    XCTAssertEqual(conversation.messages.count, messageCount+1);
    ZMClientMessage *editedMessage = conversation.messages.lastObject;
    XCTAssertEqualObjects(editedMessage.textMessageData.messageText, @"Bar");
}

- (void)testThatItSendsOutNotificationAboutUpdatedMessages
{
    // given
    XCTAssert([self logInAndWaitForSyncToBeComplete]);
    ZMConversation *conversation = [self conversationForMockConversation:self.selfToUser1Conversation];
    
    MockUserClient *fromClient = self.user1.clients.anyObject;
    MockUserClient *toClient = self.selfUser.clients.anyObject;
    ZMGenericMessage *textMessage = [ZMGenericMessage messageWithText:@"Foo" nonce:[NSUUID createUUID].transportString expiresAfter:nil];
    
    [self.mockTransportSession performRemoteChanges:^(id ZM_UNUSED session) {
        [self.selfToUser1Conversation encryptAndInsertDataFromClient:fromClient toClient:toClient data:textMessage.data];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    ZMClientMessage *receivedMessage = conversation.messages.lastObject;
    NSUUID *messageNone = receivedMessage.nonce;
    
    id convToken = [ConversationChangeInfo addObserver:self.conversationChangeObserver forConversation:conversation];
    [self.conversationChangeObserver clearNotifications];
    
    ZMConversationMessageWindow *window = [conversation conversationWindowWithSize:10];
    MessageWindowChangeObserver *windowObserver = [[MessageWindowChangeObserver alloc] initWithMessageWindow:window];
    NSUInteger messageIndex = [window.messages indexOfObject:receivedMessage];
    XCTAssertEqual(messageIndex, 0u);
    NSDate *lastModifiedDate = conversation.lastModifiedDate;
    
    // when
    ZMGenericMessage *editMessage = [ZMGenericMessage messageWithEditMessage:messageNone.transportString newText:@"Bar" nonce:[NSUUID createUUID].transportString];
    __block MockEvent *editEvent;
    [self.mockTransportSession performRemoteChanges:^(id ZM_UNUSED session) {
        editEvent = [self.selfToUser1Conversation encryptAndInsertDataFromClient:fromClient toClient:toClient data:editMessage.data];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqualObjects(conversation.lastModifiedDate, lastModifiedDate);
    XCTAssertNotEqualObjects(conversation.lastModifiedDate, editEvent.time);

    ZMClientMessage *editedMessage = conversation.messages.lastObject;
    NSUInteger editedMessageIndex = [window.messages indexOfObject:editedMessage];
    XCTAssertEqual(editedMessageIndex, messageIndex);
    
    XCTAssertEqual(self.conversationChangeObserver.notifications.count, 1u);
    ConversationChangeInfo *convInfo =  self.conversationChangeObserver.notifications.firstObject;
    XCTAssertTrue(convInfo.messagesChanged);
    XCTAssertFalse(convInfo.participantsChanged);
    XCTAssertFalse(convInfo.nameChanged);
    XCTAssertFalse(convInfo.unreadCountChanged);
    XCTAssertFalse(convInfo.lastModifiedDateChanged);
    XCTAssertFalse(convInfo.connectionStateChanged);
    XCTAssertFalse(convInfo.isSilencedChanged);
    XCTAssertFalse(convInfo.conversationListIndicatorChanged);
    XCTAssertFalse(convInfo.clearedChanged);
    XCTAssertFalse(convInfo.securityLevelChanged);

    XCTAssertEqual(windowObserver.notifications.count, 1u);
    MessageWindowChangeInfo *windowInfo = windowObserver.notifications.lastObject;
    XCTAssertEqualObjects(windowInfo.deletedIndexes, [NSIndexSet indexSetWithIndex:messageIndex]);
    XCTAssertEqualObjects(windowInfo.insertedIndexes, [NSIndexSet indexSetWithIndex:messageIndex]);
    XCTAssertEqualObjects(windowInfo.updatedIndexes, [NSIndexSet indexSet]);
    XCTAssertEqualObjects(windowInfo.movedIndexPairs, @[]);
    
    (void)convToken;
}


@end
