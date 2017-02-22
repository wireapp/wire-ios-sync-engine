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


@import UIKit;

#import "ZMUserSession.h"

extern NSString *const ZMConversationCategory;
extern NSString *const ZMConversationCategoryEphemeral;
extern NSString *const ZMConversationOpenAction;
extern NSString *const ZMConversationDirectReplyAction;
extern NSString *const ZMConversationMuteAction;

extern NSString *const ZMMessageLikeAction;

extern NSString *const ZMIncomingCallCategory;
extern NSString *const ZMMissedCallCategory;

extern NSString *const ZMCallIgnoreAction;
extern NSString *const ZMCallAcceptAction;

extern NSString *const ZMConnectCategory;
extern NSString *const ZMConnectAcceptAction;



@interface ZMUserSession (UserNotificationCategories)

- (UIUserNotificationCategory *)replyCategory;
- (UIUserNotificationCategory *)replyCategoryEphemeral;
- (UIUserNotificationCategory *)incomingCallCategory;
- (UIUserNotificationCategory *)missedCallCategory;

- (UIUserNotificationCategory *)connectCategory;

@end

