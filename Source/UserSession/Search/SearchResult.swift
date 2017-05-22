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

public struct SearchResult {
    let contacts : [ZMUser]
    let teamMembers : [Member]
    let directory : [ZMSearchUser]
    let conversations : [ZMConversation]
}

extension SearchResult {
    
    public init?(payload: [AnyHashable : Any], query: String, userSession: ZMUserSession) {
        guard let documents = payload["documents"] as? [[AnyHashable : Any]] else {
            return nil
        }
        
        let isHandleQuery = query.hasPrefix("@")
        let queryWithoutAtSymbol = (isHandleQuery ? query.substring(from: query.index(after: query.startIndex)) : query).lowercased()
        
        let filteredDocuments = documents.filter { (document) -> Bool in
            let name = document["name"] as? String
            let handle = document["handle"] as? String
            
            return !isHandleQuery || name?.hasPrefix("@") ?? true || handle?.contains(queryWithoutAtSymbol) ?? false
        }
        
        let searchUsers = ZMSearchUser.users(withPayloadArray: filteredDocuments, userSession: userSession) ?? []
        
        contacts = []
        teamMembers = []
        directory = searchUsers.filter({ !$0.isConnected })
        conversations = []
    }
    
    func copy(on context: NSManagedObjectContext) -> SearchResult {
        return self
    }
    
    func union(withLocalResult result: SearchResult) -> SearchResult {
        return SearchResult(contacts: result.contacts,teamMembers: result.teamMembers, directory: directory, conversations: result.conversations)
    }
    
    func union(withRemoteResult result: SearchResult) -> SearchResult {
        return SearchResult(contacts: contacts, teamMembers: teamMembers, directory: result.directory, conversations: conversations)
    }
    
}
