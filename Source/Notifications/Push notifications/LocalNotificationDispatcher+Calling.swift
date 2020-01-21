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

public extension LocalNotificationDispatcher {
    
    func process(callState: CallState, in conversation: ZMConversation, caller: ZMUser) {
        // missed call notification are handled separately
        // but if call was answered elsewhere then proceed
        switch callState {
        case .terminating(reason: let reason):
            switch reason {
            case .anweredElsewhere, .rejectedElsewhere: break
            default: return
            }
        default: break
        }
        
        let note = ZMLocalNotification(callState: callState, conversation: conversation, caller: caller)
        callingNotifications.cancelNotifications(conversation)
        note.apply(scheduleLocalNotification)
        note.apply(callingNotifications.addObject)
    }
    
    func processMissedCall(in conversation: ZMConversation, caller: ZMUser) {
        let note = ZMLocalNotification(callState: .terminating(reason: .canceled), conversation: conversation, caller: caller)
        callingNotifications.cancelNotifications(conversation)
        note.apply(scheduleLocalNotification)
        note.apply(callingNotifications.addObject)
    }
}
