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
import WireDataModel

public struct SearchOptions: OptionSet {
    public let rawValue: Int

    /// Users you are connected to via connection request
    public static let contacts = SearchOptions(rawValue: 1 << 0)
    /// Users found in your address book
    public static let addressBook = SearchOptions(rawValue: 1 << 1)
    /// Users which are a member of the same team as you
    public static let teamMembers = SearchOptions(rawValue: 1 << 2)
    /// Exclude team members which aren't in an active conversation with you
    public static let excludeNonActiveTeamMembers = SearchOptions(rawValue: 1 << 3)
    /// Exclude team members with the role .partner which aren't in an active conversation with you
    public static let excludeNonActivePartners = SearchOptions(rawValue: 1 << 4)
    /// Users from the public directory
    public static let directory = SearchOptions(rawValue: 1 << 5)
    /// Group conversations you are or were a participant of
    public static let conversations = SearchOptions(rawValue: 1 << 6)
    /// Services which are enabled in your team
    public static let services = SearchOptions(rawValue: 1 << 7)
    /// Users from federated servers
    public static let federated = SearchOptions(rawValue: 1 << 8)

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

}

extension SearchOptions {
    public mutating func updateForSelfUserTeamRole(selfUser: ZMUser) {
        if selfUser.teamRole == .partner {
            insert(.excludeNonActiveTeamMembers)
            remove(.directory)
        } else {
            insert(.excludeNonActivePartners)
        }
    }
}

public struct SearchRequest {

    let maxQueryLength = 200

    public init(query: String, searchOptions: SearchOptions, team: Team? = nil) {
        self.query = query.truncated(at: maxQueryLength)
        self.searchOptions = searchOptions
        self.team = team
    }

    var team: Team?
    let query: String
    let searchOptions: SearchOptions

    var normalizedQuery: String {
        return query.normalizedAndTrimmed()
    }

    var handleAndDomain: (String, String)? {
        let components = query.split(separator: "@")
            .map({ String($0).trimmingCharacters(in: .whitespaces).lowercased() })
            .filter({ !$0.isEmpty })

        guard
            let handle = components.element(atIndex: 0),
            let domain = components.element(atIndex: 1)
        else {
            return nil
        }

        return (String(handle), String(domain))
    }

}

fileprivate extension String {

    func normalizedAndTrimmed() -> String {
        guard let normalized = self.normalizedForSearch() as String? else { return "" }
        return normalized.trimmingCharacters(in: .whitespaces)
    }

}
