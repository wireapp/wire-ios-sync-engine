//
// Wire
// Copyright (C) 2017 Wire Swiss GmbH
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

@objc
public protocol ServerConnectionObserver {
    
    @objc(serverConnectionDidChange:)
    func serverConnection(didChange serverConnection : ServerConnection)
    
}

@objc
public protocol ServerConnection {
    
    var isMobileConnection : Bool { get }
    var isOffline : Bool { get }
    
    func addObserver(_ observer: ServerConnectionObserver) -> Any
    func removeObserver(_ token: Any)
}

extension AccountManager {
    
    public var serverConnection : ServerConnection? {
        return self
    }
    
}

extension AccountManager : ServerConnection {
    
    public var isOffline: Bool {
        return !transportSession.reachability.mayBeReachable
    }
    
    public var isMobileConnection: Bool {
        return transportSession.reachability.isMobileConnection
    }
    
    /// Add observer of server connection. Returns a token for de-registering the observer.
    public func addObserver(_ observer: ServerConnectionObserver) -> Any {
        
        return NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: ZMTransportSessionReachabilityChangedNotificationName),
                                                      object: nil,
                                                      queue: OperationQueue.main) { [weak observer] (note) in
                                                        observer?.serverConnection(didChange: self)
        }
    }
    
    // Remove an observer by supplying a token.
    public func removeObserver(_ token: Any) {
        NotificationCenter.default.removeObserver(token)
    }
    
}
