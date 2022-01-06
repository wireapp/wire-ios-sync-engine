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

public enum FederationError: Error {
    case domainTemporarilyNotAvailable
}

public struct SearchResult {
    public var contacts: [ZMSearchUser]
    public var teamMembers: [ZMSearchUser]
    public var addressBook: [ZMSearchUser]
    public var directory: [ZMSearchUser]
    public var federation: Swift.Result<[ZMSearchUser], FederationError>
    public var conversations: [ZMConversation]
    public var services: [ServiceUser]
}

extension SearchResult {

    public init?(payload: [AnyHashable: Any], query: String, searchOptions: SearchOptions, contextProvider: ContextProvider) {
        guard let documents = payload["documents"] as? [[String: Any]] else {
            return nil
        }

        let isHandleQuery = query.hasPrefix("@")
        let queryWithoutAtSymbol = (isHandleQuery ? String(query[query.index(after: query.startIndex)...]) : query).lowercased()

        let filteredDocuments = documents.filter { (document) -> Bool in
            let name = document["name"] as? String
            let handle = document["handle"] as? String

            return !isHandleQuery || name?.hasPrefix("@") ?? true || handle?.contains(queryWithoutAtSymbol) ?? false
        }

        let searchUsers = ZMSearchUser.searchUsers(from: filteredDocuments, contextProvider: contextProvider)

        contacts = []
        addressBook = []
        directory = searchUsers.filter({ !$0.isConnected && !$0.isTeamMember })
        federation = .success([])
        conversations = []
        services = []

        if searchOptions.contains(.teamMembers) &&
           searchOptions.isDisjoint(with: .excludeNonActiveTeamMembers) {
            teamMembers = searchUsers.filter({ $0.isTeamMember })
        } else {
            teamMembers = []
        }
    }

    public init?(servicesPayload servicesFullPayload: [AnyHashable: Any], query: String, contextProvider: ContextProvider) {
        guard let servicesPayload = servicesFullPayload["services"] as? [[String: Any]] else {
            return nil
        }

        let searchUsersServices = ZMSearchUser.searchUsers(from: servicesPayload, contextProvider: contextProvider)

        contacts = []
        teamMembers = []
        addressBook = []
        directory = []
        federation = .success([])
        conversations = []
        services = searchUsersServices
    }

    public init?(userLookupPayload: [AnyHashable: Any], contextProvider: ContextProvider
    ) {
        guard let userLookupPayload = userLookupPayload as? [String: Any],
              let searchUser = ZMSearchUser.searchUser(from: userLookupPayload, contextProvider: contextProvider),
              searchUser.user == nil ||
              searchUser.user?.isTeamMember == false else {
            return nil
        }

        contacts = []
        teamMembers = []
        addressBook = []
        directory = [searchUser]
        federation = .success([])
        conversations = []
        services = []
    }

    public init?(federationResponse response: ZMTransportResponse, contextProvider: ContextProvider) {
        let result: Swift.Result<[ZMSearchUser], FederationError>

        if response.result == .success {
            guard
                let payload = response.payload?.asDictionary() as? [String: Any],
                let searchUser = ZMSearchUser.searchUser(from: payload, contextProvider: contextProvider)
            else {
                return nil
            }

            result = .success([searchUser])
        } else if response.httpStatus == 422 || response.httpStatus == 500 {
            result = .failure(.domainTemporarilyNotAvailable)
        } else {
            return nil
        }

        contacts = []
        teamMembers = []
        addressBook = []
        directory = []
        federation = result
        conversations = []
        services = []
    }

    mutating func extendWithMembershipPayload(payload: MembershipListPayload) {
        payload.members.forEach { (membershipPayload) in
            let searchUser = teamMembers.first(where: { $0.remoteIdentifier == membershipPayload.userID })
            let permissions = membershipPayload.permissions.flatMap({ Permissions(rawValue: $0.selfPermissions) })
            searchUser?.updateWithTeamMembership(permissions: permissions, createdBy: membershipPayload.createdBy)
        }
    }

    mutating func filterBy(searchOptions: SearchOptions,
                           query: String,
                           contextProvider: ContextProvider) {
        guard searchOptions.contains(.excludeNonActivePartners) else { return }

        let selfUser = ZMUser.selfUser(in: contextProvider.viewContext)
        let isHandleQuery = query.hasPrefix("@")
        let queryWithoutAtSymbol = (isHandleQuery ? String(query[query.index(after: query.startIndex)...]) : query).lowercased()

        teamMembers = teamMembers.filter({
            $0.teamRole != .partner ||
            $0.teamCreatedBy == selfUser.remoteIdentifier ||
            isHandleQuery && $0.handle == queryWithoutAtSymbol
        })
    }

    func copy(on context: NSManagedObjectContext) -> SearchResult {

        let copiedConversations = conversations.compactMap { context.object(with: $0.objectID) as? ZMConversation }

        return SearchResult(contacts: contacts,
                            teamMembers: teamMembers,
                            addressBook: addressBook,
                            directory: directory,
                            federation: federation,
                            conversations: copiedConversations,
                            services: services)
    }

    func union(withLocalResult result: SearchResult) -> SearchResult {
        return SearchResult(contacts: result.contacts,
                            teamMembers: result.teamMembers,
                            addressBook: result.addressBook,
                            directory: directory,
                            federation: result.federation,
                            conversations: result.conversations,
                            services: services)
    }

    func union(withServiceResult result: SearchResult) -> SearchResult {
        return SearchResult(contacts: contacts,
                            teamMembers: teamMembers,
                            addressBook: addressBook,
                            directory: directory,
                            federation: federation,
                            conversations: conversations,
                            services: result.services)
    }

    func union(withDirectoryResult result: SearchResult) -> SearchResult {
        return SearchResult(contacts: contacts,
                            teamMembers: Array(Set(teamMembers).union(result.teamMembers)),
                            addressBook: addressBook,
                            directory: result.directory,
                            federation: federation,
                            conversations: conversations,
                            services: services)
    }

    func union(withFederationResult result: SearchResult) -> SearchResult {
        return SearchResult(contacts: contacts,
                            teamMembers: teamMembers,
                            addressBook: addressBook,
                            directory: directory,
                            federation: result.federation,
                            conversations: conversations,
                            services: services)
    }

}
