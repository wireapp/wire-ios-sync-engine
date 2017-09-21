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


import WireDataModel

// MARK: - Initial sync
@objc public protocol ZMInitialSyncCompletionObserver: NSObjectProtocol
{
    func initialSyncCompleted()
}

private let initialSyncCompletionNotificationName = Notification.Name(rawValue: "ZMInitialSyncCompletedNotification")


extension ZMUserSession {
    
    static func notifyInitialSyncCompleted(context: NSManagedObjectContext) {
        NotificationInContext(name: initialSyncCompletionNotificationName, context: context.zm_userInterface).post()
    }
    
    public func addInitialSyncCompletionObserver(_ observer: ZMInitialSyncCompletionObserver) -> Any {
        return ZMUserSession.addInitialSyncCompletionObserver(observer, context: managedObjectContext)
    }
    
    public static func addInitialSyncCompletionObserver(_ observer: ZMInitialSyncCompletionObserver, context: NSManagedObjectContext) -> Any {
        return NotificationInContext.addObserver(name: initialSyncCompletionNotificationName, context: context.zm_userInterface) {
            [weak observer] _ in
            observer?.initialSyncCompleted()
        }
    }
    
    public static func addInitialSyncCompletionObserver(_ observer: ZMInitialSyncCompletionObserver, userSession: ZMUserSession) -> Any {
        return self.addInitialSyncCompletionObserver(observer, context: userSession.managedObjectContext)
    }
}

// MARK: - Network Availability
@objc public class ZMNetworkAvailabilityChangeNotification : NSObject {

    private static let name = Notification.Name(rawValue: "ZMNetworkAvailabilityChangeNotification")
    
    private static let stateKey = "networkState"
    
    public static func addNetworkAvailabilityObserver(_ observer: ZMNetworkAvailabilityObserver, userSession: ZMUserSession) -> Any {
        return NotificationInContext.addObserver(name: name,
                                                 context: userSession)
        {
            [weak observer] note in
            observer?.didChangeAvailability(newState: note.userInfo[stateKey] as! ZMNetworkState)
        }
    }
    
    public static func notify(networkState: ZMNetworkState, userSession: ZMUserSession) {
        NotificationInContext(name: name, context: userSession, userInfo: [stateKey: networkState]).post()
    }

}

@objc public protocol ZMNetworkAvailabilityObserver: NSObjectProtocol {
    func didChangeAvailability(newState: ZMNetworkState)
}


// MARK: - Typing
private let typingNotificationName = Notification.Name(rawValue: "ZMTypingChangeNotification")
private let typingNotificationUsersKey = "typingUsers"

public extension ZMConversation {

    @objc public func addTypingObserver(_ observer: ZMTypingChangeObserver) -> Any {
        return NotificationInContext.addObserver(name: typingNotificationName,
                                                 context: self.managedObjectContext!.zm_userInterface)
        {
            [weak observer, weak self] note in
            guard let `self` = self else { return }
            observer?.typingDidChange(conversation: self, typingUsers: note.userInfo[typingNotificationUsersKey] as! Set<ZMUser>)
        }
    }
    
    @objc public func notifyTyping(typingUsers: Set<ZMUser>) {
        NotificationInContext(name: typingNotificationName, context: self.managedObjectContext!.zm_userInterface, userInfo: [typingNotificationUsersKey: typingUsers]).post()
    }
}


@objc public protocol ZMTypingChangeObserver: NSObjectProtocol {
    
    func typingDidChange(conversation: ZMConversation, typingUsers: Set<ZMUser>)
}

// MARK: - Connection limit reached
@objc public protocol ZMConnectionLimitObserver: NSObjectProtocol {
    
    func connectionLimitReached()
}


@objc public class ZMConnectionLimitNotification : NSObject {

    private static let name = Notification.Name(rawValue: "ZMConnectionLimitReachedNotification")
    
    public static func addConnectionLimitObserver(_ observer: ZMConnectionLimitObserver, context: NSManagedObjectContext) -> Any {
        return NotificationInContext.addObserver(name: self.name, context: context.zm_userInterface) {
            [weak observer] _ in
            observer?.connectionLimitReached()
        }
    }
    
    @objc(notifyInContext:)
    public static func notify(context: NSManagedObjectContext) {
        NotificationInContext(name: self.name, context: context.zm_userInterface).post()
    }
}



