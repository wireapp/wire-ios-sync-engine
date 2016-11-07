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


@import ZMTesting;
@import zmessaging;
@import ZMCDataModel;

#import "NSManagedObjectContext+TestHelpers.h"


@class NSManagedObjectContext;
@class MockTransportSession;
@class ZMManagedObject;
@class ZMUser;
@class ZMConversation;
@class ZMConnection;
@protocol ZMObjectStrategyDirectory;
@class ApplicationMock;
@class ZMAssetClientMessage;

@import Cryptobox;
@import zimages;
@class UserClient;

@class MockUser;
@class ZMClientMessage;

NS_ASSUME_NONNULL_BEGIN

/// This is a base test class with utility stuff for all tests.
@interface MessagingTest : ZMTBaseTest

/// Waits for queues and managed object contexts to finish work and verifies mocks
- (void)cleanUpAndVerify;

/// Wait for the block to return @c YES. The block is called on the given @c queue. The block is only called after each @c NSManagedObjectContextDidChange notification of the given context.
/// Should be wrapped in call to @c XCTAssert()
- (BOOL)waitWithTimeout:(NSTimeInterval)timeout forSaveOfContext:(NSManagedObjectContext *)moc untilBlock:(BOOL(^)(void))block ZM_MUST_USE_RETURN;

@property (nonatomic, readonly) NSManagedObjectContext *uiMOC;
@property (nonatomic, readonly) NSManagedObjectContext *syncMOC;
@property (nonatomic, readonly) NSManagedObjectContext *testMOC;
@property (nonatomic, readonly) NSManagedObjectContext *alternativeTestMOC;
@property (nonatomic, readonly) NSManagedObjectContext *searchMOC;
@property (nonatomic, readonly) ApplicationMock *application;

@property (nonatomic, readonly) MockTransportSession *mockTransportSession;

@property (nonatomic, readonly) NSString *groupIdentifier;

/// reset ui and sync contexts
- (void)resetUIandSyncContextsAndResetPersistentStore:(BOOL)resetPersistentStore;
- (void)resetUIandSyncContextsAndResetPersistentStore:(BOOL)resetPersistentStore notificationContentHidden:(BOOL)notificationContentHidden;

/// perform operations pretending that the uiMOC is a syncMOC
- (void)performPretendingUiMocIsSyncMoc:(void(^)(void))block;

- (id<ZMObjectStrategyDirectory>)createMockObjectStrategyDirectoryInMoc:(NSManagedObjectContext *)moc;

@end



@interface MessagingTest (Asynchronous)

typedef BOOL (^SaveExpectationHandler)(ZMManagedObject *);
- (XCTestExpectation *)expectationForSaveOnContext:(NSManagedObjectContext *)moc withUpdateOfClass:(Class)aClass handler:(SaveExpectationHandler)handler;

@end



@interface MessagingTest (DisplayNameGenerator)

- (void)updateDisplayNameGeneratorWithUsers:(NSArray *)users;

@end



@interface MessagingTest (AVS)

- (void)simulateMediaFlowEstablishedOnConversation:(ZMConversation *)conversation;
- (void)simulateMediaFlowReleasedOnConversation:(ZMConversation *)conversation;
- (void)simulateParticipantsChanged:(NSArray *)users onConversation:(ZMConversation *)uiConversation;

@end


@interface MessagingTest (UserTesting)

- (void)setEmailAddress:(NSString *)emailAddress onUser:(ZMUser *)user;
- (void)setPhoneNumber:(NSString *)phoneNumber onUser:(ZMUser *)user;

@end



@interface MessagingTest (FilesInCache)

+ (NSURL *)cacheFolder;
+ (void)deleteAllFilesInCache;
+ (NSSet *)filesInCache;

@end


@interface MessagingTest (OTR)



- (NSData *)encryptedMessage:(ZMGenericMessage *)message recipient:(UserClient *)recipient;

- (UserClient *)setupSelfClientInMoc:(NSManagedObjectContext *)moc;
- (UserClient *)createSelfClient;
- (UserClient *)createClientForUser:(ZMUser *)user createSessionWithSelfUser:(BOOL)createSessionWithSeflUser;
- (UserClient *)createClientForMockUser:(MockUser *)mockUser createSessionWithSelfUser:(BOOL)createSessionWithSeflUser;


- (ZMClientMessage *)createClientTextMessage:(BOOL)encrypted;
- (ZMClientMessage *)createClientTextMessage:(NSString *)text encrypted:(BOOL)encrypted;
- (ZMAssetClientMessage *)createImageMessageWithImageData:(NSData *)imageData
                                                   format:(ZMImageFormat)format
                                                processed:(BOOL)processed
                                                   stored:(BOOL)stored
                                                encrypted:(BOOL)encrypted
                                                      moc:(NSManagedObjectContext *)moc;

@end



@interface MessagingTest (SwiftBridgeConversation)

- (void)simulateUnreadCount:(NSUInteger)unreadCount forConversation:(ZMConversation *)conversation;
- (void)simulateUnreadMissedCallInConversation:(ZMConversation *)conversation;
- (void)simulateUnreadMissedKnockInConversation:(ZMConversation *)conversation;

@end

NS_ASSUME_NONNULL_END
