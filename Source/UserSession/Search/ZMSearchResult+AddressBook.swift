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
import Contacts

/// This is used for testing only
var debug_searchResultAddressBookOverride : AddressBookAccessor? = nil

extension ZMSearchResult {
    
    /// Creates a new search result with the same results and additional
    /// results obtained by searching through the address book with the same query
    public func extendWithContactsFromAddressBook(_ query: String,
                                                  userSession: ZMUserSession) -> ZMSearchResult {
        /*
         When I have a search result obtained (either with a local search or from the BE) by matching on Wire
         users display names or handle, I also want to check if I have any address book contact in my local
         address book that match the query. However, matching local contacts might overlap in a number of ways 
         with the users that I already found from the Wire search. The following code makes sure that such overlaps
         are not displayed twice (once for the Wire user, once for the address book contact).
         */
        let addressBook = AddressBookSearch(addressBook: debug_searchResultAddressBookOverride)
        
        // I don't need to find the address book contacts of users that I already found
        let identifiersOfAlreadyFoundUsers = self.usersInContacts.flatMap { $0.user?.addressBookEntry?.localIdentifier } +
            self.usersInDirectory.flatMap { $0.user?.addressBookEntry?.localIdentifier }
        let allMatchingAddressBookContacts = addressBook.contactsMatchingQuery(query, identifiersToExclude: identifiersOfAlreadyFoundUsers)

        // There might also be contacts for which the local address book name match and which are also Wire users, but on Wire their name doesn't match,
        // so the Wire search did not return them. If I figure out which Wire users they match, I want to include those users into
        // the result as Wire user results, not an non-Wire address book results
        
        let (additionalUsersFromAddressBook, addressBookContactsWithoutUser) = contactsThatAreAlsoUsers(contacts: allMatchingAddressBookContacts,
                                                                                                        managedObjectContext: userSession.managedObjectContext)
        let searchUsersFromAddressBook = addressBookContactsWithoutUser.flatMap { ZMSearchUser(contact: $0, user: nil, userSession: userSession) }
        
        // of those users, which one are connected and which one are not?
        let additionalConnectedUsers = additionalUsersFromAddressBook
            .filter { $0.connection != nil }
            .flatMap { ZMSearchUser(contact: nil, user: $0, userSession: userSession) }
        let additionalNonConnectedUsers = additionalUsersFromAddressBook
            .filter { $0.connection == nil }
            .flatMap { ZMSearchUser(contact: nil, user: $0, userSession: userSession) }
        
        return ZMSearchResult(usersInContacts: self.usersInContacts + searchUsersFromAddressBook + additionalConnectedUsers,
                              usersInDirectory: self.usersInDirectory + additionalNonConnectedUsers,
                              groupConversations: self.groupConversations)
    }
    
    /// Returns users that are linked to the given address book contacts
    private func contactsThatAreAlsoUsers(contacts: [ZMAddressBookContact], managedObjectContext: NSManagedObjectContext) -> (users: [ZMUser], nonMatchedContacts: [ZMAddressBookContact]) {
        
        guard !contacts.isEmpty else {
            return (users: [], nonMatchedContacts: [])
        }
        
        var identifiersToContact = [String : ZMAddressBookContact]()
        contacts.forEach {
            guard let identifier = $0.localIdentifier else { return }
            identifiersToContact[identifier] = $0
        }
        
        let predicate = NSPredicate(format: "addressBookEntry.localIdentifier IN %@", Set(identifiersToContact.keys))
        let fetchRequest = ZMUser.sortedFetchRequest(with: predicate)
        fetchRequest?.returnsObjectsAsFaults = false
        let users = managedObjectContext.executeFetchRequestOrAssert(fetchRequest) as! [ZMUser]
        
        for user in users {
            identifiersToContact.removeValue(forKey: user.addressBookEntry.localIdentifier!)
        }
        
        return (users: users, nonMatchedContacts: Array(identifiersToContact.values))
    }
}
