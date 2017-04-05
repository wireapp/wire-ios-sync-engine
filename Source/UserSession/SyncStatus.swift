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

@objc public enum SyncPhase : Int {
    case fetchingLastUpdateEventID, fetchingConnections, fetchingConversations, fetchingUsers, fetchingMissedEvents, done
    
    var isLastSlowSyncPhase : Bool {
        return self == .fetchingUsers
    }
    
    var isSyncing : Bool {
        switch self {
        case .fetchingMissedEvents, .fetchingLastUpdateEventID, .fetchingConnections,.fetchingUsers, .fetchingConversations:
            return true
        case .done:
            return false
        }
    }
}

public class SyncStatus : NSObject {

    fileprivate var previousPhase : SyncPhase = .done
    public internal (set) var currentSyncPhase : SyncPhase = .done {
        didSet {
            if currentSyncPhase != oldValue {
                previousPhase = oldValue
            }
        }
    }

    fileprivate var lastUpdateEventID : UUID?
    fileprivate unowned var managedObjectContext: NSManagedObjectContext
    fileprivate unowned var syncStateDelegate: ZMSyncStateDelegate
    
    public internal (set) var isInBackground : Bool = false
    public internal (set) var needsToRestartQuickSync : Bool = false
    fileprivate var pushChannelIsOpen : Bool = false
    public var isSyncing : Bool {
        return currentSyncPhase.isSyncing
    }
    
    public init(managedObjectContext: NSManagedObjectContext, syncStateDelegate: ZMSyncStateDelegate) {
        self.managedObjectContext = managedObjectContext
        self.syncStateDelegate = syncStateDelegate
        super.init()
        
        currentSyncPhase = hasPersistedLastEventID ? .fetchingMissedEvents : .fetchingLastUpdateEventID
    }
}

// MARK: Slow Sync
extension SyncStatus {
    
    public func didStart(_ phase: SyncPhase){
        guard !previousPhase.isSyncing else { return }
        syncStateDelegate.didStartSync()
    }
    
    public func didFinish(_ phase: SyncPhase) {
        guard phase == currentSyncPhase,
              let newPhase = SyncPhase(rawValue:currentSyncPhase.rawValue+1)
        else { return }
        
        if phase.isLastSlowSyncPhase {
            persistLastUpdateEventID()
        }
        
        currentSyncPhase = newPhase
        if currentSyncPhase == .done {
            if needsToRestartQuickSync && pushChannelIsOpen {
                // If the push channel closed while fetching notifications
                // We need to restart fetching the notification stream since we might be missing notifications
                currentSyncPhase = .fetchingMissedEvents
                needsToRestartQuickSync = false
                return
            }
            syncStateDelegate.didFinishSync()
            managedObjectContext.zm_userInterface.perform{
                ZMUserSession.notifyInitialSyncCompleted()
            }
        }
        RequestAvailableNotification.notifyNewRequestsAvailable(self)
    }
    
    public func didFail(_ phase: SyncPhase) {
        guard phase == currentSyncPhase else { return }
        if phase == .fetchingMissedEvents {
            currentSyncPhase = hasPersistedLastEventID ? .fetchingConnections : .fetchingLastUpdateEventID
            needsToRestartQuickSync = false
        }
    }
    
    var hasPersistedLastEventID : Bool {
        return managedObjectContext.zm_lastNotificationID != nil
    }
    
    public func updateLastUpdateEventID(eventID : UUID) {
        lastUpdateEventID = eventID
    }
    
    public func persistLastUpdateEventID() {
        guard let lastUpdateEventID = lastUpdateEventID else { return }
        managedObjectContext.zm_lastNotificationID = lastUpdateEventID
    }
}

// MARK: Quick Sync
extension SyncStatus {
    
    public func pushChannelDidClose() {
        pushChannelIsOpen = false
        
        if !currentSyncPhase.isSyncing {
            // As soon as the pushChannel closes we should notify the UI that we are syncing (if we are not already syncing)
            self.syncStateDelegate.didStartSync()
        }
    }
    
    public func pushChannelDidOpen() {
        pushChannelIsOpen = true
        
        if currentSyncPhase == .fetchingMissedEvents {
            // If the pushChannel closed while we are fetching the notifications, we might be missing notifications that are sent between the server response and the channel reopening
            // We therefore need to mark the quicksync to be restarted
            needsToRestartQuickSync = true
        }
        startQuickSyncIfNeeded()
    }
    
    func startQuickSyncIfNeeded() {
        guard self.currentSyncPhase == .done else { return }
        self.currentSyncPhase = .fetchingMissedEvents
    }
}

