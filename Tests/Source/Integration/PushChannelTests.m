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


@import WireMockTransport;
@import WireDataModel;

#import "IntegrationTestBase.h"
#import "ZMUserSession+Internal.h"
#import "ZMMissingUpdateEventsTranscoder+Internal.h"

@interface PushChannelTests : IntegrationTestBase

@end

@implementation PushChannelTests

- (void)testThatWeReceiveRemoteMessagesWhenThePushChannelIsUp
{
    // given
    NSString *testMessage1 = [NSString stringWithFormat:@"%@ message 1", self.name];
    NSString *testMessage2 = [NSString stringWithFormat:@"%@ message 22", self.name];
    
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    ZMUser *sender = [self userForMockUser:self.user1];

    // when
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        NOT_USED(session);
        // send new message remotely
        ZMGenericMessage *message = [ZMGenericMessage messageWithText:testMessage1 nonce:NSUUID.createUUID.transportString expiresAfter:nil];
        MockUserClient *fromClient = self.user1.clients.anyObject, *toClient = self.selfUser.clients.anyObject;
        [self.groupConversation encryptAndInsertDataFromClient:fromClient toClient:toClient data:message.data];
        [self spinMainQueueWithTimeout:0.2];
        
        ZMGenericMessage *secondMessage = [ZMGenericMessage messageWithText:testMessage2 nonce:NSUUID.createUUID.transportString expiresAfter:nil];
        [self.groupConversation encryptAndInsertDataFromClient:fromClient toClient:toClient data:secondMessage.data];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    WaitForAllGroupsToBeEmpty(0.5);

    // then
    ZMConversation *groupConversation = [self conversationForMockConversation:self.groupConversation];
    id<ZMConversationMessage> message1 = groupConversation.messages[groupConversation.messages.count -2];
    id<ZMConversationMessage> message2 = groupConversation.messages.lastObject;
    
    XCTAssertEqualObjects(message1.textMessageData.messageText, testMessage1);
    XCTAssertEqualObjects(message2.textMessageData.messageText, testMessage2);
    XCTAssertEqualObjects(message1.sender, sender);
    XCTAssertEqualObjects(message2.sender, sender);
}

- (void)testThatItFetchesLastNotificationsFromBackendIgnoringTransientNotificationsID
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        NOT_USED(session);
        [self.groupConversation addUserToCall:self.user1];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
            NOT_USED(session);
        // will create a notification that is not transient
        ZMGenericMessage *message = [ZMGenericMessage messageWithText:@"Food" nonce:NSUUID.createUUID.transportString expiresAfter:nil];
        [self.groupConversation encryptAndInsertDataFromClient:self.user1.clients.anyObject toClient:self.selfUser.clients.anyObject data:message.data];
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    
    __block NSUUID *messageAddLastNotificationID;
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        NOT_USED(session);
        // save previous notification ID
        MockPushEvent *messageEvent = self.mockTransportSession.updateEvents.lastObject;
        messageAddLastNotificationID = messageEvent.uuid;
        XCTAssertEqualObjects(messageEvent.payload[@"type"], @"conversation.otr-message-add");
        
        // will create a transient notification
        [self.groupConversation addUserToCall:self.user2];
        
    }];
    WaitForAllGroupsToBeEmpty(0.5);
    [self.mockTransportSession resetReceivedRequests];
    
    // when
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        [session simulatePushChannelClosed];
    }];
    WaitForAllGroupsToBeEmpty(0.5);

    // then
    NSString *expectedLastRequest = [NSString stringWithFormat:@"/notifications?size=%lu&since=%@&client=%@", ZMMissingUpdateEventsTranscoderListPageSize, messageAddLastNotificationID.transportString, self.userSession.selfUserClient.remoteIdentifier];
    XCTAssertEqualObjects([(ZMTransportRequest *)self.mockTransportSession.receivedRequests.lastObject path], expectedLastRequest);
    ZMConversation *syncConv = (id)[self.userSession.syncManagedObjectContext objectWithID:[self conversationForMockConversation:self.groupConversation].objectID];
    [syncConv.voiceChannelRouter.v2 tearDown];
}



@end
