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
@import WireRequestStrategy;

#import "ZMUpdateEventsBuffer.h"

@class ZMTransportRequest;
@class LocalNotificationDispatcher;
@class ApplicationStatusDirectory;
@class CallingRequestStrategy;
@class ZMMissingUpdateEventsTranscoder;

@protocol ZMTransportData;
@protocol ZMSyncStateDelegate;
@protocol ApplicationStateOwner;
@protocol ZMApplication;
@protocol LocalStoreProviderProtocol;
@protocol EventProcessingTrackerProtocol;
@protocol StrategyDirectoryProtocol;

@interface ZMSyncStrategy : NSObject <TearDownCapable, RequestStrategy>

- (instancetype _Nonnull )initWithStoreProvider:(id<LocalStoreProviderProtocol> _Nonnull)storeProvider
                        notificationsDispatcher:(NotificationDispatcher * _Nonnull)notificationsDispatcher
                     applicationStatusDirectory:(ApplicationStatusDirectory * _Nonnull)applicationStatusDirectory
                                    application:(id<ZMApplication> _Nonnull)application
                              strategyDirectory:(id<StrategyDirectoryProtocol> _Nonnull)strategyDirectory
                         eventProcessingTracker:(id<EventProcessingTrackerProtocol> _Nonnull)eventProcessingTracker;

- (void)applyHotFixes;

- (ZMTransportRequest *_Nullable)nextRequest;

- (void)tearDown;

@property (nonatomic, readonly, nonnull) NSManagedObjectContext *syncMOC;
@property (nonatomic, weak, readonly, nullable) ApplicationStatusDirectory *applicationStatusDirectory;
@property (nonatomic, readonly, nonnull) CallingRequestStrategy *callingRequestStrategy;
@property (nonatomic, readonly, nonnull) ZMMissingUpdateEventsTranscoder *missingUpdateEventsTranscoder;
@property (nonatomic, readonly, nonnull) NSArray<id<ZMEventConsumer>> *eventConsumers;
@property (nonatomic, weak, readonly, nullable) LocalNotificationDispatcher *localNotificationDispatcher;
@property (nonatomic, nullable) id<EventProcessingTrackerProtocol> eventProcessingTracker;
@end

