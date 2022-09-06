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
import WireDataModel

// Temporary Mock until we find a way to use a single mocked `MLSControllerProcotol` accross frameworks
class MockMLSController: MLSControllerProtocol {
    func uploadKeyPackagesIfNeeded() {

    }

    func createGroup(for groupID: MLSGroupID) throws {

    }

    func conversationExists(groupID: MLSGroupID) -> Bool {
        return true
    }

    func processWelcomeMessage(welcomeMessage: String) throws -> MLSGroupID {
        return MLSGroupID(Bytes())
    }

    func encrypt(message: Bytes, for groupID: MLSGroupID) throws -> Bytes {
        return []
    }

    func decrypt(message: String, for groupID: MLSGroupID) throws -> Data? {
        return nil
    }

    func addMembersToConversation(with users: [MLSUser], for groupID: MLSGroupID) async throws {

    }

    func removeMembersFromConversation(with clientIds: [MLSClientID], for groupID: MLSGroupID) async throws {

    }

    func addGroupPendingJoin(_ group: MLSGroup) {

    }

    var didCallJoinGroupsStillPending: Bool = false
    func joinGroupsStillPending() {
        didCallJoinGroupsStillPending = true
    }

}
