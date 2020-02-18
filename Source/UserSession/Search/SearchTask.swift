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
import WireUtilities

public class SearchTask {
    
    public enum Task {
        case search(searchRequest: SearchRequest)
        case lookup(userId: UUID)
    }
    
    public typealias ResultHandler = (_ result: SearchResult, _ isCompleted: Bool) -> Void
 
    fileprivate let transportSession: TransportSessionType
    fileprivate let searchContext: NSManagedObjectContext
    fileprivate let contextProvider: ZMManagedObjectContextProvider
    fileprivate let task: Task
    fileprivate var userLookupTaskIdentifier: ZMTaskIdentifier?
    fileprivate var directoryTaskIdentifier: ZMTaskIdentifier?
    fileprivate var handleTaskIdentifier: ZMTaskIdentifier?
    fileprivate var servicesTaskIdentifier: ZMTaskIdentifier?
    fileprivate var resultHandlers: [ResultHandler] = []
    fileprivate var result: SearchResult = SearchResult(contacts: [], teamMembers: [], addressBook: [],  directory: [], conversations: [], services: [])
    
    fileprivate var tasksRemaining = 0 {
        didSet {
            // only trigger handles if decrement to 0
            if oldValue > tasksRemaining {
                let isCompleted = tasksRemaining == 0
                resultHandlers.forEach { $0(result, isCompleted) }
                
                if isCompleted {
                    resultHandlers.removeAll()
                }
            }
        }
    }
    
    convenience init(request: SearchRequest,
                     searchContext: NSManagedObjectContext,
                     contextProvider: ZMManagedObjectContextProvider,
                     transportSession: TransportSessionType) {
        self.init(task: .search(searchRequest: request), searchContext: searchContext, contextProvider: contextProvider, transportSession: transportSession)
    }
    
    convenience init(lookupUserId userId: UUID,
                     searchContext: NSManagedObjectContext,
                     contextProvider: ZMManagedObjectContextProvider,
                     transportSession: TransportSessionType) {
        self.init(task: .lookup(userId: userId), searchContext: searchContext, contextProvider: contextProvider, transportSession: transportSession)
    }
    
    public init(task: Task, searchContext: NSManagedObjectContext, contextProvider: ZMManagedObjectContextProvider, transportSession: TransportSessionType) {
        self.task = task
        self.transportSession = transportSession
        self.searchContext = searchContext
        self.contextProvider = contextProvider
    }
    
    /// Add a result handler
    public func onResult(_ resultHandler : @escaping ResultHandler) {
        resultHandlers.append(resultHandler)
    }
    
    /// Cancel a previously started task
    public func cancel() {
        resultHandlers.removeAll()
        
        userLookupTaskIdentifier.flatMap(transportSession.cancelTask)
        directoryTaskIdentifier.flatMap(transportSession.cancelTask)
        servicesTaskIdentifier.flatMap(transportSession.cancelTask)
        handleTaskIdentifier.flatMap(transportSession.cancelTask)
        
        tasksRemaining = 0
    }
    
    /// Start the search task. Results will be sent to the result handlers
    /// added via the `onResult()` method.
    public func start() {
        performLocalSearch()

        performRemoteSearch()
        performRemoteSearchForTeamUser()
        performRemoteSearchForServices()

        performUserLookup()
        performLocalLookup()
    }
}

extension SearchTask {


    /// look up a user ID from contacts and teamMmebers locally. 
    private func performLocalLookup() {
         guard case .lookup(let userId) = task else { return }

        tasksRemaining += 1

        searchContext.performGroupedBlock {
            let selfUser = ZMUser.selfUser(in: self.searchContext)

            var options = SearchOptions()

            options.updateForSelfUserTeamRole(selfUser: selfUser)

            ///search for the local user with matching user ID and active
            let activeMembers = self.teamMembers(matchingQuery: "", team: selfUser.team, searchOptions: options)
            let teamMembers = activeMembers.filter({ $0.remoteIdentifier == userId})

            let connectedUsers = self.connectedUsers(matchingQuery: "").filter({ $0.remoteIdentifier == userId})
            let result = SearchResult(contacts: connectedUsers,
                                      teamMembers: teamMembers,
                                      addressBook: [], directory: [], conversations: [], services: [])

            self.contextProvider.managedObjectContext.performGroupedBlock {
                self.result = self.result.union(withLocalResult: result.copy(on: self.contextProvider.managedObjectContext))

                self.tasksRemaining -= 1
            }
        }
    }

    func performLocalSearch() {
        guard case .search(let request) = task else { return }
        
        tasksRemaining += 1
        
        searchContext.performGroupedBlock {
            
            var team : Team? = nil
            if let teamObjectID = request.team?.objectID {
                team = (try? self.searchContext.existingObject(with: teamObjectID)) as? Team
            }
            
            let connectedUsers = request.searchOptions.contains(.contacts) ? self.connectedUsers(matchingQuery: request.normalizedQuery) : []
            let teamMembers = request.searchOptions.contains(.teamMembers) ? self.teamMembers(matchingQuery: request.normalizedQuery, team: team, searchOptions: request.searchOptions) : []
            let conversations = request.searchOptions.contains(.conversations) ? self.conversations(matchingQuery: request.query) : []
            let result = SearchResult(contacts: connectedUsers, teamMembers: teamMembers, addressBook: [], directory: [], conversations: conversations, services: [])
            
            self.contextProvider.managedObjectContext.performGroupedBlock {
                self.result = self.result.union(withLocalResult: result.copy(on: self.contextProvider.managedObjectContext))
                
                if request.searchOptions.contains(.addressBook) {
                    self.result = self.result.extendWithContactsFromAddressBook(request.normalizedQuery, contextProvider: self.contextProvider)
                }
                
                self.tasksRemaining -= 1
            }
        }
    }

    private func filterNonActiveTeamMembers(members: [Member]) -> [Member] {
        let activeConversations = ZMUser.selfUser(in: searchContext).activeConversations
        let activeContacts = Set(activeConversations.flatMap({ $0.localParticipants }))
        let selfUser = ZMUser.selfUser(in: searchContext)

        return members.filter({
            guard let user = $0.user else { return false }
            return selfUser.membership?.createdBy == user || activeContacts.contains(user)
        })
    }

    func teamMembers(matchingQuery query : String, team: Team?, searchOptions: SearchOptions) -> [Member] {
        var result =  team?.members(matchingQuery: query) ?? []
        
        if searchOptions.contains(.excludeNonActiveTeamMembers) {
            result = filterNonActiveTeamMembers(members: result)
        }
        
        if searchOptions.contains(.excludeNonActivePartners) {
            let query = query.strippingLeadingAtSign()
            let selfUser = ZMUser.selfUser(in: searchContext)
            let activeConversations = ZMUser.selfUser(in: searchContext).activeConversations
            let activeContacts = Set(activeConversations.flatMap({ $0.localParticipants }))
            
            result = result.filter({
                if let user = $0.user {
                    return user.teamRole != .partner || user.handle == query || user.membership?.createdBy == selfUser || activeContacts.contains(user)
                } else {
                    return false
                }
            })
        }
        
        return result
    }
    
    func connectedUsers(matchingQuery query: String) -> [ZMUser] {
        let fetchRequest = ZMUser.sortedFetchRequest(with: ZMUser.predicateForConnectedUsers(withSearch: query))
        return searchContext.executeFetchRequestOrAssert(fetchRequest) as? [ZMUser] ?? []
    }
    
    func conversations(matchingQuery query: String) -> [ZMConversation] {
        ///TODO: use the interface with tean param?
        let fetchRequest = ZMConversation.sortedFetchRequest(with: ZMConversation.predicate(forSearchQuery: query, selfUser: ZMUser.selfUser(in: searchContext)))
        fetchRequest?.sortDescriptors = [NSSortDescriptor(key: ZMNormalizedUserDefinedNameKey, ascending: true)]
        var conversations = searchContext.executeFetchRequestOrAssert(fetchRequest) as? [ZMConversation] ?? []
        
        if query.hasPrefix("@") {
            // if we are searching for a username only include conversations with matching displayName
            conversations = conversations.filter { $0.displayName.contains(query)}
        }
        
        let matchingPredicate = ZMConversation.userDefinedNamePredicate(forSearch: query)
        var matching : [ZMConversation] = []
        var nonMatching : [ZMConversation] = []
        
        // re-sort conversations without a matching userDefinedName to the end of the result list
        conversations.forEach { (conversation) in
            if matchingPredicate.evaluate(with: conversation) {
                matching.append(conversation)
            } else {
                nonMatching.append(conversation)
            }
        }
        
        return matching + nonMatching
    }
    
}

extension SearchTask {
    
    func performUserLookup() {
        guard case .lookup(let userId) = task else { return }
        
        tasksRemaining += 1
        
        searchContext.performGroupedBlock {
            let request  = type(of: self).searchRequestForUser(withUUID: userId)
            
            request.add(ZMCompletionHandler(on: self.contextProvider.managedObjectContext, block: { [weak self] (response) in
                defer {
                    self?.tasksRemaining -= 1
                }
                
                guard
                    let contextProvider = self?.contextProvider,
                    let payload = response.payload?.asDictionary(),
                    let result = SearchResult(userLookupPayload: payload, contextProvider: contextProvider)
                    else {
                        return
                }
                
                if let updatedResult = self?.result.union(withDirectoryResult: result) {
                    self?.result = updatedResult
                }
            }))
            
            request.add(ZMTaskCreatedHandler(on: self.searchContext, block: { [weak self] (taskIdentifier) in
                self?.userLookupTaskIdentifier = taskIdentifier
            }))
            
            self.transportSession.enqueueOneTime(request)
        }
        
    }
    
    static func searchRequestForUser(withUUID uuid : UUID) -> ZMTransportRequest {
        return ZMTransportRequest(getFromPath: "/users/\(uuid.transportString())")
    }
    
}

extension SearchTask {
    
    func performRemoteSearch() {
        guard case .search(let searchRequest) = task, searchRequest.searchOptions.contains(.directory) else { return }
        
        tasksRemaining += 1
        
        searchContext.performGroupedBlock {
            let request = type(of: self).searchRequestInDirectory(withQuery: searchRequest.query)
            
            request.add(ZMCompletionHandler(on: self.contextProvider.managedObjectContext, block: { [weak self] (response) in
                
                defer {
                    self?.tasksRemaining -= 1
                }
                
                guard
                    let contextProvider = self?.contextProvider,
                    let payload = response.payload?.asDictionary(),
                    let result = SearchResult(payload: payload, query: searchRequest.query, contextProvider: contextProvider)
                else {
                    return
                }
                
                if let updatedResult = self?.result.union(withDirectoryResult: result) {
                    self?.result = updatedResult
                }
            }))
            
            request.add(ZMTaskCreatedHandler(on: self.searchContext, block: { [weak self] (taskIdentifier) in
                self?.directoryTaskIdentifier = taskIdentifier
            }))
            
            self.transportSession.enqueueOneTime(request)
        }
    }
    
    static func searchRequestInDirectory(withQuery query : String, fetchLimit: Int = 10) -> ZMTransportRequest {
        var query = query
        
        if query.hasPrefix("@") {
            query = String(query[query.index(after: query.startIndex)...])
        }
        
        var url = URLComponents()
        url.path = "/search/contacts"
        url.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "size", value: String(fetchLimit))]
        let urlStr = url.string?.replacingOccurrences(of: "+", with: "%2B") ?? ""
        return ZMTransportRequest(getFromPath: urlStr)
    }
    
}

extension SearchTask {
    
    func performRemoteSearchForTeamUser() {
        guard case .search(let searchRequest) = task, searchRequest.searchOptions.contains(.directory) else { return }
        
        tasksRemaining += 1
        
        searchContext.performGroupedBlock {
            let request = type(of: self).searchRequestInDirectory(withHandle: searchRequest.query)
            
            request.add(ZMCompletionHandler(on: self.contextProvider.managedObjectContext, block: { [weak self] (response) in
                
                defer {
                    self?.tasksRemaining -= 1
                }
                
                guard
                    let contextProvider = self?.contextProvider,
                    let payload = response.payload?.asArray(),
                    let userPayload = (payload.first as? ZMTransportData)?.asDictionary()
                    else {
                        return
                }
                
                guard
                    let handle = userPayload["handle"] as? String,
                    let name = userPayload["name"] as? String,
                    let id = userPayload["id"] as? String
                    else {
                        return
                }
                
                let document = ["handle": handle, "name": name, "id": id]
                let documentPayload = ["documents": [document]]
                guard let result = SearchResult(payload: documentPayload, query: searchRequest.query, contextProvider: contextProvider) else {
                    return
                }
                
                if let user = result.directory.first, !user.isSelfUser {
                    if let prevResult = self?.result {
                        // prepend result to prevResult only if it doesn't contain it
                        if !prevResult.directory.contains(user) {
                            self?.result = SearchResult(
                                contacts: prevResult.contacts,
                                teamMembers: prevResult.teamMembers,
                                addressBook: prevResult.addressBook,
                                directory: result.directory + prevResult.directory,
                                conversations: prevResult.conversations,
                                services: prevResult.services
                            )
                        }
                    } else {
                        self?.result = result
                    }
                }
                
            }))
            
            request.add(ZMTaskCreatedHandler(on: self.searchContext, block: { [weak self] (taskIdentifier) in
                self?.handleTaskIdentifier = taskIdentifier
            }))
            
            self.transportSession.enqueueOneTime(request)
        }
    }
    
    static func searchRequestInDirectory(withHandle handle : String) -> ZMTransportRequest {
        var handle = handle.lowercased()
        
        if handle.hasPrefix("@") {
            handle = String(handle[handle.index(after: handle.startIndex)...])
        }
        
        var url = URLComponents()
        url.path = "/users"
        url.queryItems = [URLQueryItem(name: "handles", value: handle)]
        let urlStr = url.string?.replacingOccurrences(of: "+", with: "%2B") ?? ""
        return ZMTransportRequest(getFromPath: urlStr)
    }
}

extension SearchTask {
    
    func performRemoteSearchForServices() {
        guard case .search(let searchRequest) = task, searchRequest.searchOptions.contains(.services) else { return }
        
        tasksRemaining += 1

        searchContext.performGroupedBlock {
            let selfUser = ZMUser.selfUser(in: self.searchContext)
            guard let teamIdentifier = selfUser.team?.remoteIdentifier else { return }

            let request = type(of: self).servicesSearchRequest(teamIdentifier: teamIdentifier, query: searchRequest.query)
            
            request.add(ZMCompletionHandler(on: self.contextProvider.managedObjectContext, block: { [weak self] (response) in
                
                defer {
                    self?.tasksRemaining -= 1
                }
                
                guard
                    let contextProvider = self?.contextProvider,
                    let payload = response.payload?.asDictionary(),
                    let result = SearchResult(servicesPayload: payload, query: searchRequest.query, contextProvider: contextProvider)
                    else {
                        return
                }
                
                if let updatedResult = self?.result.union(withServiceResult: result) {
                    self?.result = updatedResult
                }
            }))
            
            request.add(ZMTaskCreatedHandler(on: self.searchContext, block: { [weak self] (taskIdentifier) in
                self?.servicesTaskIdentifier = taskIdentifier
            }))
            
            self.transportSession.enqueueOneTime(request)
        }
    }
    
    static func servicesSearchRequest(teamIdentifier: UUID, query: String) -> ZMTransportRequest {
        var url = URLComponents()
        url.path = "/teams/\(teamIdentifier.transportString())/services/whitelisted"

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            url.queryItems = [URLQueryItem(name: "prefix", value: trimmedQuery)]
        }
        let urlStr = url.string?.replacingOccurrences(of: "+", with: "%2B") ?? ""
        return ZMTransportRequest(getFromPath: urlStr)
    }
}
