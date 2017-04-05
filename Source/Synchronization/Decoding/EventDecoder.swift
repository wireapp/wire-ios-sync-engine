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
import WireCryptobox
import WireDataModel
import WireMessageStrategy

private let zmLog = ZMSLog(tag: "EventDecoder")

/// Key used in persistent store metadata
private let previouslyReceivedEventIDsKey = "zm_previouslyReceivedEventIDsKey"

/// Holds a list of received event IDs
@objc public protocol PreviouslyReceivedEventIDsCollection : NSObjectProtocol {
    
    func discardListOfAlreadyReceivedPushEventIDs()
}



/// Decodes and stores events from various sources to be processed later
@objc public final class EventDecoder: NSObject {
    
    public typealias ConsumeBlock = (([ZMUpdateEvent]) -> Void)
    
    static var BatchSize : Int {
        if let testingBatchSize = testingBatchSize {
            return testingBatchSize
        }
        return 500
    }
    
    /// Set this for testing purposes only
    static var testingBatchSize : Int?
    
    let eventMOC : NSManagedObjectContext
    let syncMOC: NSManagedObjectContext
    
    fileprivate typealias EventsWithStoredEvents = (storedEvents: [StoredUpdateEvent], updateEvents: [ZMUpdateEvent])
    
    public init(eventMOC: NSManagedObjectContext, syncMOC: NSManagedObjectContext) {
        self.eventMOC = eventMOC
        self.syncMOC = syncMOC
        super.init()
        self.eventMOC.performGroupedBlockAndWait {
            self.createReceivedPushEventIDsStoreIfNecessary()
        }
    }
}

// MARK: - Process events
extension EventDecoder {
    
    /// Decrypts passed in events and stores them in chronological order in a persisted database. It then saves the database and cryptobox
    /// It then calls the passed in block (multiple times if necessary), returning the decrypted events
    /// If the app crashes while processing the events, they can be recovered from the database
    public func processEvents(_ events: [ZMUpdateEvent], block: ConsumeBlock) {
     
        
        var lastIndex: Int64?
        
        eventMOC.performGroupedBlockAndWait {
            
            self.storeReceivedPushEventIDs(from: events)
            let filteredEvents = self.filterAlreadyReceivedEvents(from: events)
            
            // Get the highest index of events in the DB
            lastIndex = StoredUpdateEvent.highestIndex(self.eventMOC)
            
            guard let index = lastIndex else { return }
            self.storeEvents(filteredEvents, startingAtIndex: index)
        }
        
        process(block, firstCall: true)
    }
    
    /// Decrypts and stores the decrypted events as `StoreUpdateEvent` in the event database.
    /// The encryption context is only closed after the events have been stored, which ensures
    /// they can be decrypted again in case of a crash.
    /// - parameter events The new events that should be decrypted and stored in the database.
    /// - parameter startingAtIndex The startIndex to be used for the incrementing sortIndex of the stored events.
    fileprivate func storeEvents(_ events: [ZMUpdateEvent], startingAtIndex startIndex: Int64) {
        syncMOC.zm_cryptKeyStore.encryptionContext.perform { [weak self] (sessionsDirectory) -> Void in
            guard let `self` = self else { return }
            
            let newUpdateEvents = events.flatMap { event -> ZMUpdateEvent? in
                if event.type == .conversationOtrMessageAdd || event.type == .conversationOtrAssetAdd {
                    return sessionsDirectory.decryptAndAddClient(event, in: self.syncMOC)
                } else {
                    return event
                }
            }
            
            // This call has to be synchronous to ensure that we close the
            // encryption context only if we stored all events in the database
            self.eventMOC.performGroupedBlockAndWait {
                
                // Insert the decryted events in the event database using a `storeIndex`
                // incrementing from the highest index currently stored in the database
                for (idx, event) in newUpdateEvents.enumerated() {
                    _ = StoredUpdateEvent.create(event, managedObjectContext: self.eventMOC, index: Int64(idx) + startIndex + 1)
                }

                self.eventMOC.saveOrRollback()
            }
        }
    }
    
    // Processes the stored events in the database in batches of size EventDecoder.BatchSize` and calls the `consumeBlock` for each batch.
    // After the `consumeBlock` has been called the stored events are deleted from the database.
    // This method terminates when no more events are in the database.
    private func process(_ consumeBlock: ConsumeBlock, firstCall: Bool) {
        let events = fetchNextEventsBatch()
        guard events.storedEvents.count > 0 else {
            if firstCall {
                consumeBlock([])
            }
            return
        }

        processBatch(events.updateEvents, storedEvents: events.storedEvents, block: consumeBlock)
        process(consumeBlock, firstCall: false)
    }
    
    /// Calls the `ComsumeBlock` and deletes the respective stored events subsequently.
    private func processBatch(_ events: [ZMUpdateEvent], storedEvents: [NSManagedObject], block: ConsumeBlock) {
        block(events)
        
        eventMOC.performGroupedBlockAndWait {
            storedEvents.forEach(self.eventMOC.delete(_:))
            self.eventMOC.saveOrRollback()
        }
    }
    
    /// Fetches and returns the next batch of size `EventDecoder.BatchSize` 
    /// of `StoredEvents` and `ZMUpdateEvent`'s in a `EventsWithStoredEvents` tuple.
    private func fetchNextEventsBatch() -> EventsWithStoredEvents {
        var (storedEvents, updateEvents)  = ([StoredUpdateEvent](), [ZMUpdateEvent]())

        eventMOC.performGroupedBlockAndWait {
            storedEvents = StoredUpdateEvent.nextEvents(self.eventMOC, batchSize: EventDecoder.BatchSize)
            updateEvents = StoredUpdateEvent.eventsFromStoredEvents(storedEvents)
        }
        return (storedEvents: storedEvents, updateEvents: updateEvents)
    }
    
}

// MARK: - List of already received event IDs
extension EventDecoder {
    
    /// create event ID store if needed
    fileprivate func createReceivedPushEventIDsStoreIfNecessary() {
        if self.eventMOC.persistentStoreMetadata(forKey: previouslyReceivedEventIDsKey) as? [String] == nil {
            self.eventMOC.setPersistentStoreMetadata(array: [String](), key: previouslyReceivedEventIDsKey)
        }
    }
    
    
    /// List of already received event IDs
    fileprivate var alreadyReceivedPushEventIDs : Set<UUID> {
        let array = self.eventMOC.persistentStoreMetadata(forKey: previouslyReceivedEventIDsKey) as! [String]
        return Set(array.flatMap { UUID(uuidString: $0) })
    }
    
    /// List of already received event IDs as strings
    fileprivate var alreadyReceivedPushEventIDsStrings : Set<String> {
        return Set(self.eventMOC.persistentStoreMetadata(forKey: previouslyReceivedEventIDsKey) as! [String])
    }
    
    /// Store received event IDs 
    fileprivate func storeReceivedPushEventIDs(from: [ZMUpdateEvent]) {
        let uuidToAdd = from
            .filter { $0.source == .pushNotification }
            .flatMap { $0.uuid }
            .map { $0.transportString() }
        let allUuidStrings = self.alreadyReceivedPushEventIDsStrings.union(uuidToAdd)
        
        self.eventMOC.setPersistentStoreMetadata(array: Array(allUuidStrings), key: previouslyReceivedEventIDsKey)
    }
    
    /// Filters out events that have been received before
    fileprivate func filterAlreadyReceivedEvents(from: [ZMUpdateEvent]) -> [ZMUpdateEvent] {
        let eventIDsToDiscard = self.alreadyReceivedPushEventIDs
        return from.flatMap { event -> ZMUpdateEvent? in
            if event.source != .pushNotification, let uuid = event.uuid {
                return eventIDsToDiscard.contains(uuid) ? nil : event
            } else {
                return event
            }
        }
    }
}

extension EventDecoder : PreviouslyReceivedEventIDsCollection {
    
    /// Discards the list of already received events
    public func discardListOfAlreadyReceivedPushEventIDs() {
        self.eventMOC.performGroupedBlockAndWait {
            self.eventMOC.setPersistentStoreMetadata(array: [String](), key: previouslyReceivedEventIDsKey)
        }
    }
}
