//
// Wire
// Copyright (C) 2022 Wire Swiss GmbH
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
import CallKit

struct CallHandle: Hashable {

    // MARK: - Properties

    let accountID: UUID
    let conversationID: UUID

    private static let separator: Character = "+"

    // MARK: - Life cycle

    init(
        accountID: UUID,
        conversationID: UUID
    ) {
        self.accountID = accountID
        self.conversationID = conversationID
    }

    init?(encodedString: String) {
        let identifiers = encodedString
            .split(separator: Self.separator)
            .map(String.init)
            .compactMap(UUID.init(uuidString:))

        guard identifiers.count == 2 else {
            return nil
        }

        accountID = identifiers[0]
        conversationID = identifiers[1]
    }

    // MARK: - Methods

    var cxHandle: CXHandle {
        return CXHandle(type: .generic, value: encodedString)
    }

    var encodedString: String {
        return "\(accountID.transportString())\(Self.separator)\(conversationID.transportString())"
    }

}
