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


@objcMembers public class SearchDirectory : NSObject {
    
    let searchContext : NSManagedObjectContext
    let userSession : ZMUserSession
    var isTornDown = false
    
    deinit {
        assert(isTornDown, "`tearDown` must be called before SearchDirectory is deinitialized")
    }
    
    public init(userSession: ZMUserSession) {
        self.userSession = userSession
        self.searchContext = userSession.searchManagedObjectContext
    }

    /// Perform a search request.
    ///
    /// Returns a SearchTask which should be retained until the results arrive.
    public func perform(_ request: SearchRequest) -> SearchTask {
        let task = SearchTask(request: request, context: searchContext, session: userSession)
        
        task.onResult { [weak self] (result, _) in
            self?.observeSearchUsers(result)
        }
        
        return task
    }
    
    func observeSearchUsers(_ result : SearchResult) {
        let searchUserObserverCenter = userSession.managedObjectContext.searchUserObserverCenter
        result.directory.forEach(searchUserObserverCenter.addSearchUser)
        result.services.compactMap { $0 as? ZMSearchUser }.forEach(searchUserObserverCenter.addSearchUser)
    }
    
}

extension SearchDirectory: TearDownCapable {
    /// Tear down the SearchDirectory.
    ///
    /// NOTE: this must be called before releasing the instance
    public func tearDown() {
        // Evict all cached search users
        userSession.managedObjectContext.zm_searchUserCache?.removeAllObjects()

        // Reset search user observer center to remove unnecessarily observed search users
        userSession.managedObjectContext.searchUserObserverCenter.reset()

        isTornDown = true
    }
}
