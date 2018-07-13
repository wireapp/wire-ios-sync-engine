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


import WireTesting
@testable import WireSyncEngine

class UpdateEventsStoreMigrationTests: MessagingTest {
    
    var applicationContainer: URL {
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("StorageStackTests")
    }
    
    var previousEventStoreLocations : [URL] {
        return [
            sharedContainerURL,
            sharedContainerURL.appendingPathComponent(userIdentifier.uuidString)
            ].map({ $0.appendingPathComponent("ZMEventModel.sqlite")})
    }
    
    func testThatItMigratesTheStoreFromOldLocation() throws {
        
        for oldEventStoreLocation in previousEventStoreLocations {
            
            // given
            StorageStack.shared.createStorageAsInMemory = false
            try FileManager.default.createDirectory(at: oldEventStoreLocation.deletingLastPathComponent(), withIntermediateDirectories: true)
            let eventMOC_oldLocation = NSManagedObjectContext.createEventContext(at: oldEventStoreLocation)
            eventMOC_oldLocation.add(self.dispatchGroup)
            
            // given
            let conversation = ZMConversation.insertNewObject(in: self.uiMOC)
            conversation.remoteIdentifier = UUID.create()
            let payload = self.payloadForMessage(in: conversation, type: EventConversationAdd, data: ["foo": "bar"])!
            let event = ZMUpdateEvent(fromEventStreamPayload: payload, uuid: UUID.create())!
            
            guard let storedEvent1 = StoredUpdateEvent.create(event, managedObjectContext: eventMOC_oldLocation, index: 0),
                let storedEvent2 = StoredUpdateEvent.create(event, managedObjectContext: eventMOC_oldLocation, index: 1),
                let storedEvent3 = StoredUpdateEvent.create(event, managedObjectContext: eventMOC_oldLocation, index: 2)
                else {
                    return XCTFail("Could not create storedEvents")
            }
            try eventMOC_oldLocation.save()
            let objectIDs = Set([storedEvent1, storedEvent2, storedEvent3].map { $0.objectID.uriRepresentation() })
            eventMOC_oldLocation.tearDownEventMOC()
            XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
            
            // when
            let eventMOC = NSManagedObjectContext.createEventContext(withSharedContainerURL: sharedContainerURL, userIdentifier: userIdentifier)
            let batch = StoredUpdateEvent.nextEvents(eventMOC, batchSize: 4)
            
            // then
            XCTAssertEqual(batch.count, 3)
            let loadedObjectIDs = Set(batch.map { $0.objectID.uriRepresentation() })
            
            XCTAssertEqual(objectIDs, loadedObjectIDs)
            batch.forEach{ XCTAssertFalse($0.isFault) }
            
            // cleanup
            removeFilesInSharedContainer()
            
        }
    }
    
    func testThatItReopensTheExistingStoreInNewLocation() throws {
        // given
        StorageStack.shared.createStorageAsInMemory = false
        let eventMOC_sameLocation = NSManagedObjectContext.createEventContext(withSharedContainerURL: sharedContainerURL, userIdentifier: userIdentifier)
        eventMOC_sameLocation.add(self.dispatchGroup)
        
        // given
        let conversation = ZMConversation.insertNewObject(in: self.uiMOC)
        conversation.remoteIdentifier = UUID.create()
        let payload = self.payloadForMessage(in: conversation, type: EventConversationAdd, data: ["foo": "bar"])!
        let event = ZMUpdateEvent(fromEventStreamPayload: payload, uuid: UUID.create())!
        
        guard let storedEvent1 = StoredUpdateEvent.create(event, managedObjectContext: eventMOC_sameLocation, index: 0),
            let storedEvent2 = StoredUpdateEvent.create(event, managedObjectContext: eventMOC_sameLocation, index: 1),
            let storedEvent3 = StoredUpdateEvent.create(event, managedObjectContext: eventMOC_sameLocation, index: 2)
            else {
                return XCTFail("Could not create storedEvents")
        }
        try eventMOC_sameLocation.save()
        let objectIDs = Set([storedEvent1, storedEvent2, storedEvent3].map { $0.objectID.uriRepresentation() })
        eventMOC_sameLocation.tearDownEventMOC()
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // when
        let eventMOC = NSManagedObjectContext.createEventContext(withSharedContainerURL: sharedContainerURL, userIdentifier: userIdentifier)
        let batch = StoredUpdateEvent.nextEvents(eventMOC, batchSize: 4)
        
        // then
        XCTAssertEqual(batch.count, 3)
        let loadedObjectIDs = Set(batch.map { $0.objectID.uriRepresentation() })
        
        XCTAssertEqual(objectIDs, loadedObjectIDs)
        batch.forEach{ XCTAssertFalse($0.isFault) }
    }
}


class StoreUpdateEventTests: MessagingTest {

    var eventMOC: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        eventMOC = NSManagedObjectContext.createEventContext(withSharedContainerURL: sharedContainerURL, userIdentifier: userIdentifier)
        eventMOC.add(self.dispatchGroup)
    }
    
    override func tearDown() {
        XCTAssertTrue(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        eventMOC.tearDownEventMOC()
        eventMOC = nil
        super.tearDown()
    }
    
    func testThatYouCanCreateAnEvent() {
        
        // given
        let conversation = ZMConversation.insertNewObject(in: self.uiMOC)
        conversation.remoteIdentifier = UUID.create()
        let payload = self.payloadForMessage(in: conversation, type: EventConversationAdd, data: ["foo": "bar"])!
        let event = ZMUpdateEvent(fromEventStreamPayload: payload, uuid: UUID.create())!
        event.appendDebugInformation("Highly informative description")
        
        // when
        if let storedEvent = StoredUpdateEvent.create(event, managedObjectContext: eventMOC, index: 2) {
            
            // then
            XCTAssertEqual(storedEvent.debugInformation, event.debugInformation)
            XCTAssertEqual(storedEvent.payload, event.payload as NSDictionary)
            XCTAssertEqual(storedEvent.isTransient, event.isTransient)
            XCTAssertEqual(storedEvent.source, Int16(event.source.rawValue))
            XCTAssertEqual(storedEvent.sortIndex, 2)
            XCTAssertEqual(storedEvent.uuidString, event.uuid?.transportString())
        } else {
            XCTFail("Did not create storedEvent")
        }
    }
    
    func testThatItFetchesAllStoredEvents() {
        
        // given
        let conversation = ZMConversation.insertNewObject(in: self.uiMOC)
        conversation.remoteIdentifier = UUID.create()
        let payload = self.payloadForMessage(in: conversation, type: EventConversationAdd, data: ["foo": "bar"])!
        let event = ZMUpdateEvent(fromEventStreamPayload: payload, uuid: UUID.create())!
        
        guard let storedEvent1 = StoredUpdateEvent.create(event, managedObjectContext: eventMOC, index: 0),
            let storedEvent2 = StoredUpdateEvent.create(event, managedObjectContext: eventMOC, index: 1),
            let storedEvent3 = StoredUpdateEvent.create(event, managedObjectContext: eventMOC, index: 2)
            else {
                return XCTFail("Could not create storedEvents")
        }
        
        // when
        let batch = StoredUpdateEvent.nextEvents(eventMOC, batchSize: 4)
        
        // then
        XCTAssertEqual(batch.count, 3)
        XCTAssertTrue(batch.contains(storedEvent1))
        XCTAssertTrue(batch.contains(storedEvent2))
        XCTAssertTrue(batch.contains(storedEvent3))
        batch.forEach{ XCTAssertFalse($0.isFault) }
    }
    
    func testThatItOrdersEventsBySortIndex() {
        
        // given
        let conversation = ZMConversation.insertNewObject(in: self.uiMOC)
        conversation.remoteIdentifier = UUID.create()
        let payload = payloadForMessage(in: conversation, type: EventConversationAdd, data: ["foo": "bar"])
        let event = ZMUpdateEvent(fromEventStreamPayload: payload!, uuid: UUID.create())!
        
        guard let storedEvent1 = StoredUpdateEvent.create(event, managedObjectContext: eventMOC, index: 0),
            let storedEvent2 = StoredUpdateEvent.create(event, managedObjectContext: eventMOC, index: 30),
            let storedEvent3 = StoredUpdateEvent.create(event, managedObjectContext: eventMOC, index: 10)
            else {
                return XCTFail("Could not create storedEvents")
        }
        
        // when
        let storedEvents = StoredUpdateEvent.nextEvents(eventMOC, batchSize: 3)
        
        // then
        XCTAssertEqual(storedEvents[0], storedEvent1)
        XCTAssertEqual(storedEvents[1], storedEvent3)
        XCTAssertEqual(storedEvents[2], storedEvent2)
    }
    
    func testThatItReturnsOnlyDefinedBatchSize() {
        
        // given
        let conversation = ZMConversation.insertNewObject(in: self.uiMOC)
        conversation.remoteIdentifier = UUID.create()
        let payload = payloadForMessage(in: conversation, type: EventConversationAdd, data: ["foo": "bar"])
        let event = ZMUpdateEvent(fromEventStreamPayload: payload!, uuid: UUID.create())!
        
        guard let storedEvent1 = StoredUpdateEvent.create(event, managedObjectContext: eventMOC, index: 0),
            let storedEvent2 = StoredUpdateEvent.create(event, managedObjectContext: eventMOC, index: 10),
            let storedEvent3 = StoredUpdateEvent.create(event, managedObjectContext: eventMOC, index: 30)
            else {
                return XCTFail("Could not create storedEvents")
        }
        
        // when
        let firstBatch = StoredUpdateEvent.nextEvents(eventMOC, batchSize: 2)
        
        // then
        XCTAssertEqual(firstBatch.count, 2)
        XCTAssertTrue(firstBatch.contains(storedEvent1))
        XCTAssertTrue(firstBatch.contains(storedEvent2))
        XCTAssertFalse(firstBatch.contains(storedEvent3))
        
        // when
        firstBatch.forEach(eventMOC.delete)
        let secondBatch = StoredUpdateEvent.nextEvents(eventMOC, batchSize: 2)
        
        // then
        XCTAssertEqual(secondBatch.count, 1)
        XCTAssertTrue(secondBatch.contains(storedEvent3))
    }
    
    func testThatItReturnsHighestIndex() {
        
        // given
        let conversation = ZMConversation.insertNewObject(in: self.uiMOC)
        conversation.remoteIdentifier = UUID.create()
        let payload = payloadForMessage(in: conversation, type: EventConversationAdd, data: ["foo": "bar"])!
        let event = ZMUpdateEvent(fromEventStreamPayload: payload, uuid: UUID.create())!
        
        guard let _ = StoredUpdateEvent.create(event, managedObjectContext: eventMOC, index: 0),
            let _ = StoredUpdateEvent.create(event, managedObjectContext: eventMOC, index: 1),
            let _ = StoredUpdateEvent.create(event, managedObjectContext: eventMOC, index: 2)
            else {
                return XCTFail("Could not create storedEvents")
        }
        
        // when
        let highestIndex = StoredUpdateEvent.highestIndex(eventMOC)
        
        // then
        XCTAssertEqual(highestIndex, 2)
    }
    
    func testThatItCanConvertAnEventToStoredEventAndBack() {
        
        // given
        let conversation = ZMConversation.insertNewObject(in: self.uiMOC)
        conversation.remoteIdentifier = UUID.create()
        let payload = payloadForMessage(in: conversation, type: EventConversationAdd, data: ["foo": "bar"])!
        let event = ZMUpdateEvent(fromEventStreamPayload: payload, uuid: UUID.create())!
        
        // when
        guard let storedEvent = StoredUpdateEvent.create(event, managedObjectContext: eventMOC, index: 0)
            else {
                return XCTFail("Could not create storedEvents")
                
        }
        
        guard let restoredEvent = StoredUpdateEvent.eventsFromStoredEvents([storedEvent]).first
            else {
                return XCTFail("Could not create original event")
        }
        
        // then
        XCTAssertEqual(restoredEvent, event)
        XCTAssertEqual(restoredEvent.payload["foo"] as? String, event.payload["foo"] as? String)
        XCTAssertEqual(restoredEvent.isTransient, event.isTransient)
        XCTAssertEqual(restoredEvent.source, event.source)
        XCTAssertEqual(restoredEvent.uuid, event.uuid)
        
    }
}
