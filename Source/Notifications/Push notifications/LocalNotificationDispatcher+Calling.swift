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
    
    public func process(callState: CallState, in conversation: ZMConversation, sender: ZMUser) {
        
        let note = ZMLocalNote(callState: callState, conversation: conversation, sender: sender)
        note.apply(scheduleLocalNotification)
        
        // TODO: cancelling other call notes for this conversation?
//        callingNotifications.cancelNotifications(conversation)
    }
    
    public func processMissedCall(in conversation: ZMConversation, sender: ZMUser) {
        
        let note = ZMLocalNote(callState: .terminating(reason: .canceled), conversation: conversation, sender: sender)
        note.apply(scheduleLocalNotification)
        
        // cancel all other call notifications for this conversation?
//        callingNotifications.cancelNotifications(conversation)
    }
    
    private func notification(for conversation: ZMConversation, sender: ZMUser) -> ZMLocalNotificationForCallState {
        if let callStateNote = callingNotifications.notifications.first(where: { $0.isCallStateNote(for: conversation, by: sender) }) as? ZMLocalNotificationForCallState {
            return callStateNote
        }
        
        return ZMLocalNotificationForCallState(conversation: conversation, sender: sender)
    }
    
}

extension ZMLocalNotification {
    
    /// Returns whether this notification is a call state notification matching conversation and sender
    fileprivate func isCallStateNote(for conversation: ZMConversation, by sender: ZMUser) -> Bool {
        guard let callStateNotification = self as? ZMLocalNotificationForCallState,
            callStateNotification.conversation == conversation,
            callStateNotification.sender == sender
        else {
                return false
        }
        return true
    }
}
