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

@class ZMUpdateEvent;

@protocol ZMUpdateEventConsumer <NSObject>

- (void)consumeUpdateEvents:(NSArray<ZMUpdateEvent *>* _Nonnull)updateEvents NS_SWIFT_NAME(consume(updateEvents:));

@end

@protocol ZMUpdateEventsFlushableCollection <NSObject>

/// process all events in the buffer
- (void)processAllEventsInBuffer;

@end


@interface ZMUpdateEventsBuffer : NSObject <ZMUpdateEventsFlushableCollection>

- (instancetype _Nonnull )initWithUpdateEventConsumer:(id <ZMUpdateEventConsumer> _Nonnull)eventConsumer;

/// discard all events in the buffer
- (void)discardAllUpdateEvents;

/// discard the event with this identifier
- (void)discardUpdateEventWithIdentifier:(NSUUID *_Nonnull)eventIdentifier;

- (void)addUpdateEvent:(ZMUpdateEvent *_Nonnull)event;

- (NSArray *_Nonnull)updateEvents;

@end
