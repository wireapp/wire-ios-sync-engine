//
// Wire
// Copyright (C) 2018 Wire Swiss GmbH
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
import UserNotifications

/**
 * The categories of notifications supported by the app.
 */

enum PushNotificationCategory: String {
    
    case incomingCall = "incomingCallCategory"
    case missedCall = "missedCallCategory"
    case conversation = "conversationCategory"
    case conversationIncludingLike = "conversationCategoryWithLike"
    case connect = "connectCategory"

    /// All the supported categories.
    static var allCategories: Set<UNNotificationCategory> {
        let categories = [PushNotificationCategory.incomingCall,
                          PushNotificationCategory.missedCall,
                          PushNotificationCategory.conversation,
                          PushNotificationCategory.conversationIncludingLike,
                          PushNotificationCategory.connect].map(\.userNotificationCategory)

        return Set(categories)
    }

    /// The actions for notifications of this category.
    var actions: [NotificationAction] {
        switch self {
        case .incomingCall:
            return [CallNotificationAction.ignore, CallNotificationAction.message]
        case .missedCall:
            return [CallNotificationAction.callBack, CallNotificationAction.message]
        case .conversation:
            return [ConversationNotificationAction.reply]
        case .conversationIncludingLike:
            return [ConversationNotificationAction.reply, ConversationNotificationAction.like]
        case .connect:
            return [ConversationNotificationAction.connect]
        }
    }

    /// The representation of the category that can be used with `UserNotifications` API.
    var userNotificationCategory: UNNotificationCategory {
        let userActions = self.actions.map(\.userAction)
        return UNNotificationCategory(identifier: rawValue, actions: userActions, intentIdentifiers: [], options: [])
    }
    
}
