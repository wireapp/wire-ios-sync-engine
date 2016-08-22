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
import ZMUtilities

/// Mark: - Encoding
extension AddressBook {
    
    func encodeWithCompletionHandler(groupQueue: ZMSGroupQueue,
                                     startingContactIndex: UInt,
                                     maxNumberOfContacts: UInt,
                                     completion: (EncodedAddressBookChunk?)->()
        ) {
        groupQueue.dispatchGroup.asyncOnQueue(addressBookProcessingQueue) { [weak self] in
            guard let strongSelf = self else {
                return
            }
            
            let range = startingContactIndex..<(startingContactIndex+maxNumberOfContacts)
            let cards = strongSelf.generateContactCards(range)
            guard cards.count > 0 else {
                groupQueue.performGroupedBlock({
                    completion(nil)
                })
                return
            }
            let cardsRange = startingContactIndex..<(startingContactIndex+UInt(cards.count))
            let encodedAB = EncodedAddressBookChunk(numberOfTotalContacts: strongSelf.numberOfContacts,
                                                    otherContactsHashes: cards,
                                                    includedContacts: cardsRange)
            groupQueue.performGroupedBlock({ 
                completion(encodedAB)
            })
        }
    }
    
    /// Generate contact cards for the given range of contacts
    private func generateContactCards(range: Range<UInt>) -> [[String]]
    {
        return self.iterate()
            .elements(range)
            .map { (contact: ZMAddressBookContact) -> [String] in
                return (contact.emailAddresses.map { $0.base64EncodedSHADigest })
                    + (contact.phoneNumbers.map { $0.base64EncodedSHADigest })
            }   
    }
}

// MARK: - Encoded address book chunk
struct EncodedAddressBookChunk {
    
    /// Total number of contacts in the address book
    let numberOfTotalContacts : UInt
    
    /// Data to upload for contacts other that the self user
    let otherContactsHashes : [[String]]
    
    /// Contacts included in this chuck, according to AB order
    let includedContacts : Range<UInt>
}


// MARK: - Utilities
extension String {
    
    /// Returns the base64 encoded string of the SHA hash of the string
    var base64EncodedSHADigest : String {
        return self.dataUsingEncoding(NSUTF8StringEncoding)!.zmSHA256Digest().base64EncodedStringWithOptions([])
    }
    
}


/// Private AB processing queue
private let addressBookProcessingQueue = dispatch_queue_create("Address book processing", DISPATCH_QUEUE_SERIAL)

extension SequenceType {
    
    /// Returns the elements of the sequence in the positions indicated by the range
    func elements(range: Range<UInt>) -> Array<Self.Generator.Element> {
        var count : UInt = 0
        var selectedElements : Array<Self.Generator.Element> = []
        for element in self {
            defer {
                count += 1
            }
            if count < range.startIndex {
                continue
            }
            if count == range.endIndex {
                break
            }
            selectedElements.append(element)
        }
        return selectedElements
    }
}
