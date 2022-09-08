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

class MockCoreCrypto: CoreCryptoProtocol {
    func wire_setCallbacks(callbacks: CoreCryptoCallbacks) throws {

    }

    func wire_clientPublicKey() throws -> [UInt8] {
        return []
    }

    func wire_clientKeypackages(amountRequested: UInt32) throws -> [[UInt8]] {
        return []
    }

    func wire_clientValidKeypackagesCount() throws -> UInt64 {
        return 0
    }

    func wire_createConversation(conversationId: ConversationId, config: ConversationConfiguration) throws {

    }

    func wire_conversationExists(conversationId: ConversationId) -> Bool {
        return true
    }

    func wire_processWelcomeMessage(welcomeMessage: [UInt8]) throws -> ConversationId {
        return ConversationId()
    }

    func wire_addClientsToConversation(conversationId: ConversationId, clients: [Invitee]) throws -> MemberAddedMessages {
        return MemberAddedMessages(commit: [], welcome: [], publicGroupState: [])
    }

    func wire_removeClientsFromConversation(conversationId: ConversationId, clients: [ClientId]) throws -> CommitBundle {
        return CommitBundle(welcome: nil, commit: [], publicGroupState: [])
    }

    func wire_wipeConversation(conversationId: ConversationId) throws {

    }

    func wire_decryptMessage(conversationId: ConversationId, payload: [UInt8]) throws -> DecryptedMessage {
        return DecryptedMessage(message: nil, proposals: [], isActive: true, commitDelay: nil)
    }

    func wire_encryptMessage(conversationId: ConversationId, message: [UInt8]) throws -> [UInt8] {
        return []
    }

    func wire_newAddProposal(conversationId: ConversationId, keyPackage: [UInt8]) throws -> [UInt8] {
        return []
    }

    func wire_newUpdateProposal(conversationId: ConversationId) throws -> [UInt8] {
        return []
    }

    func wire_newRemoveProposal(conversationId: ConversationId, clientId: ClientId) throws -> [UInt8] {
        return []
    }

    func wire_newExternalAddProposal(conversationId: ConversationId, epoch: UInt64) throws -> [UInt8] {
        return []
    }

    func wire_newExternalRemoveProposal(conversationId: ConversationId, epoch: UInt64, keyPackageRef: [UInt8]) throws -> [UInt8] {
        return []
    }

    func wire_updateKeyingMaterial(conversationId: ConversationId) throws -> CommitBundle {
        return CommitBundle(welcome: nil, commit: [], publicGroupState: [])
    }

    func wire_joinByExternalCommit(groupState: [UInt8]) throws -> MlsConversationInitMessage {
        return MlsConversationInitMessage(group: [], commit: [])
    }

    func wire_exportGroupState(conversationId: ConversationId) throws -> [UInt8] {
        return []
    }

    func wire_mergePendingGroupFromExternalCommit(conversationId: ConversationId, config: ConversationConfiguration) throws {

    }

    func wire_randomBytes(length: UInt32) throws -> [UInt8] {
        return []
    }

    func wire_reseedRng(seed: [UInt8]) throws {

    }

    func wire_commitAccepted(conversationId: ConversationId) throws {

    }

    func wire_commitPendingProposals(conversationId: ConversationId) throws -> CommitBundle {
        return CommitBundle(welcome: nil, commit: [], publicGroupState: [])
    }

}
