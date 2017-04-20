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


#import "ZMSyncStrategy.h"
@class ZMGSMCallHandler;

@interface ZMSyncStrategy (Internal)

@property (atomic, readonly) BOOL tornDown;
@property (nonatomic, weak, readonly) NSManagedObjectContext *uiMOC;
@property (nonatomic, readonly) EventDecoder *eventDecoder;
@property (nonatomic, readonly) ZMUpdateEventsBuffer *eventsBuffer;
@property (nonatomic, weak, readonly) LocalNotificationDispatcher *localNotificationDispatcher;
@property (nonatomic, readonly) NotificationDispatcher *notificationDispatcher;
@property (nonatomic, readonly) NSArray<ZMObjectSyncStrategy *> *requestStrategies;
@property (nonatomic, readonly) NSArray<id<ZMContextChangeTracker>> *allChangeTrackers;
@property (nonatomic, readonly) NSArray<id<ZMEventConsumer>> *eventConsumers;

@end


@interface ZMSyncStrategy (Badge)

- (void)updateBadgeCount;

@end


@interface ZMSyncStrategy (AppBackgroundForeground)

- (void)appDidEnterBackground:(NSNotification *)note;
- (void)appWillEnterForeground:(NSNotification *)note;

@end


@interface ZMSyncStrategy (Testing)

@property (nonatomic) BOOL contextMergingDisabled;
@property (nonatomic, readonly) ZMGSMCallHandler *gsmCallHandler;

- (ZMFetchRequestBatch *)fetchRequestBatchForEvents:(NSArray<ZMUpdateEvent *> *)events;

@end


