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


@import Foundation;
@import WireTesting;
@import WireSyncEngine;
@import WireDataModel;
@import WireMessageStrategy;

#import "IntegrationTestBase.h"
#import "ZMUserSession.h"
#import "ZMUser+Testing.h"

@interface UserTests : IntegrationTestBase

@end



@implementation UserTests

- (NSArray *)allVisibileUsers
{
    return @[self.user1, self.user2, self.user3, self.selfUser];
}

- (NSArray *)visibleUsersWithPicture
{
    NSMutableArray *usersWithPicture = [NSMutableArray array];
    
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        NOT_USED(session);
        for(MockUser *user in [self allVisibileUsers]) {
            if(user.smallProfileImageIdentifier != nil) {
                [usersWithPicture addObject:user];
            }
        }
    }];
    
    return usersWithPicture;
}

- (void)testThatSelfUserImagesAreDownloaded
{
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForEverythingToBeDone();
    
    // then
    XCTAssertTrue([ZMUser selfUserInUserSession:self.userSession].imageMediumData != nil);
    XCTAssertTrue([ZMUser selfUserInUserSession:self.userSession].imageSmallProfileData != nil);
}

- (void)testThatAllUsersAreDownloaded
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    // then
    for(MockUser *mockUser in self.allVisibileUsers) {
        ZMUser *user = [self userForMockUser:mockUser];
        [user assertMatchesUser:mockUser failureRecorder:NewFailureRecorder()];
    }
}

- (void)testThatUserSmallImageIsRedownloaded
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    ZMUser *someUser = [self userForMockUser:self.allVisibileUsers.firstObject];
    someUser.imageSmallProfileData = [self verySmallJPEGData];
    NSData *imageData = [someUser imageSmallProfileData];
    XCTAssertNotNil(imageData);
    
    [(NSCache *)someUser.managedObjectContext.userInfo[@"userImagesCache"] removeAllObjects];
    [someUser requestSmallProfileImageInUserSession:self.userSession];
    
    WaitForEverythingToBeDone();
    NSData *newImageData = [someUser imageSmallProfileData];
    XCTAssertNotNil(newImageData);
}

- (void)testThatUserMediumImageIsRedownloaded
{
    // given
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    
    ZMUser *someUser = [self userForMockUser:self.allVisibileUsers.firstObject];
    someUser.imageMediumData = [self verySmallJPEGData];
    NSData *imageData = [someUser imageMediumData];
    XCTAssertNotNil(imageData);
    
    [(NSCache *)someUser.managedObjectContext.userInfo[@"userImagesCache"] removeAllObjects];
    [someUser requestMediumProfileImageInUserSession:self.userSession];
    
    WaitForEverythingToBeDone();
    NSData *newImageData = [someUser imageMediumData];
    XCTAssertNotNil(newImageData);
}


- (void)testThatDisplayNameDoesNotChangesIfAUserWithADifferentNameIsAdded
{
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForEverythingToBeDone();
    
    // Create a conversation and change SelfUser name
    
    ZMConversation *conversation = [self conversationForMockConversation:self.groupConversation];
    (void) conversation.lastModifiedDate;
    
    ZMUser<ZMEditableUser> *selfUser = [ZMUser selfUserInUserSession:self.userSession];
    [self.userSession performChanges:^{
        selfUser.name = @"Super Name";
    }];
    WaitForAllGroupsToBeEmpty(0.2);
    
    XCTAssertEqualObjects(selfUser.displayName, @"Super");
    
    // initialize observers
    
    UserChangeObserver *userObserver = [[UserChangeObserver alloc] initWithUser:selfUser];
    
    // when
    // add new user to groupConversation remotely
    
    __block MockUser *extraUser;
    [self.mockTransportSession performRemoteChanges:^(MockTransportSession<MockTransportSessionObjectCreation> *session) {
        extraUser = [session insertUserWithName:@"Max Tester"];
        [self storeRemoteIDForObject:extraUser];
        [self.groupConversation addUsersByUser:self.selfUser addedUsers:@[extraUser]];
        XCTAssertNotNil(extraUser.name);
    }];
    WaitForEverythingToBeDone();
    
    // then
    
    ZMUser *realUser = [self userForMockUser:extraUser];
    XCTAssertEqualObjects(realUser.name, @"Max Tester");
    XCTAssertTrue([conversation.activeParticipants containsObject:realUser]);
    
    
    NSArray *userNotes = userObserver.notifications;
    XCTAssertEqual(userNotes.count, 0u);
    
    XCTAssertEqualObjects(realUser.displayName, @"Max");
    XCTAssertEqualObjects(selfUser.displayName, @"Super");
}

- (void)testThatClientsGetAddedAndDeletedForUserWhenRequested
{
    XCTAssertTrue([self logInAndWaitForSyncToBeComplete]);
    WaitForEverythingToBeDone();
    
    // given
    NSString *firstIdentifier  = @"aba6d37a35e64c4f";
    NSString *secondIdentifier = @"7c0b949c48e63f61";
    NSString *thirdIdentifier  = @"8d1b050d59f74g72";
    NSString *userID = [self userForMockUser:self.user1].remoteIdentifier.transportString;
    NSString *clientsPath = [NSString stringWithFormat:@"users/%@/clients", userID];
    
    self.mockTransportSession.responseGeneratorBlock = ^ZMTransportResponse *(ZMTransportRequest *request) {
        if ([request.path containsString:clientsPath]) {
            id <ZMTransportData> payload = [self payloadForUserClientsWithIDs:[NSSet setWithObjects:firstIdentifier, secondIdentifier, nil]];
            return [ZMTransportResponse responseWithPayload:payload HTTPStatus:200 transportSessionError:nil];
        }
        return nil;
    };
    
    // when
    ZMUser *user = [self userForMockUser:self.user1];
    [user fetchUserClients];
    WaitForEverythingToBeDone();
    
    NSSet <NSString *>*remoteIdentifiers = [user.clients mapWithBlock:^NSString *(UserClient *userClient) {
        return userClient.remoteIdentifier;
    }];
    
    // then
    XCTAssertEqual(user.clients.count, 2lu);
    XCTAssertTrue([remoteIdentifiers containsObject:firstIdentifier]);
    XCTAssertTrue([remoteIdentifiers containsObject:secondIdentifier]);
    XCTAssertTrue(![remoteIdentifiers containsObject:thirdIdentifier]);
    
    self.mockTransportSession.responseGeneratorBlock = ^ZMTransportResponse *(ZMTransportRequest *request) {
        if ([request.path containsString:clientsPath]) {
            id <ZMTransportData> payload = [self payloadForUserClientsWithIDs:[NSSet setWithObjects:secondIdentifier, thirdIdentifier, nil]];
            return [ZMTransportResponse responseWithPayload:payload HTTPStatus:200 transportSessionError:nil];
        }
        return nil;
    };
    
    // when
    [user fetchUserClients];
    WaitForEverythingToBeDone();
    
    remoteIdentifiers = [user.clients mapWithBlock:^NSString *(UserClient *userClient) {
        return userClient.remoteIdentifier;
    }];
    
    // then
    XCTAssertEqual(user.clients.count, 2lu);
    XCTAssertTrue([remoteIdentifiers containsObject:secondIdentifier]);
    XCTAssertTrue([remoteIdentifiers containsObject:thirdIdentifier]);
    XCTAssertTrue(![remoteIdentifiers containsObject:firstIdentifier]);
}

- (id <ZMTransportData>)payloadForUserClientsWithIDs:(NSSet<NSString *>*)identifiers
{
    
    NSMutableArray *payload = [[NSMutableArray alloc] init];
    for (NSString *identifier in identifiers) {
        [payload addObject:@{
                             @"id": identifier,
                             @"class": @"phone"
                             }];
    }
    return payload;
}
@end
