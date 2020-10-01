//
// Wire
// Copyright (C) 2018 Wire Swiss GmbH
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

class CallParticipantsSnapshot {

    // MARK: - Properties

    private unowned var callCenter: WireCallCenterV3
    private let conversationId: UUID

    private(set) var members: OrderedSetState<AVSCallMember> {
        didSet {
            updateParticipantTrust()
        }
    }

    private var allParticipantsAreTrusted = false {
        didSet {
            guard oldValue && !allParticipantsAreTrusted else { return }
            callCenter.closeCall(conversationId: conversationId, reason: .securityDegraded)
        }
    }

    /// Worst network quality of all the participants.

    var networkQuality: NetworkQuality {
        return members.array
            .map(\.networkQuality)
            .sorted { $0.rawValue < $1.rawValue }
            .last ?? .normal
    }

    // MARK: - Life Cycle

    init(conversationId: UUID, members: [AVSCallMember], callCenter: WireCallCenterV3) {
        self.callCenter = callCenter
        self.conversationId = conversationId
        self.members = type(of: self).removeDuplicateMembers(members)
    }

    // MARK: - Updates

    func callParticipantsChanged(participants: [AVSCallMember]) {
        members = type(of:self).removeDuplicateMembers(participants)
        notifyChange()
    }

    func callParticipantNetworkQualityChanged(client: AVSClient, networkQuality: NetworkQuality) {
        guard let localMember = findMember(with: client) else { return }

        let updatedMember = AVSCallMember(client: client,
                                          audioState: localMember.audioState,
                                          videoState: localMember.videoState,
                                          microphoneState: localMember.microphoneState,
                                          networkQuality: networkQuality)

        members = OrderedSetState(array: members.array.map({ member in
            member == localMember ? updatedMember : member
        }))
    }

    private func updateParticipantTrust() {
        guard
            let moc = callCenter.uiMOC,
            let selfClient = ZMUser.selfUser(in: moc).selfClient()
            else {
                return
        }

        let trustedClients = selfClient.trustedClients.compactMap(\.remoteIdentifier)

        allParticipantsAreTrusted = members.array.lazy
            .map(\.client.clientId)
            .allSatisfy(trustedClients.contains)
    }

    // MARK: - Helpers

    /// Returns the member matching the given userId and clientId.

    private func findMember(with client: AVSClient) -> AVSCallMember? {
        return members.array.first { $0.client == client }
    }

    /// Notifies observers of a potential change in the participants set.

    private func notifyChange() {
        guard let context = callCenter.uiMOC else { return }
        
        let participants = members
            .map { CallParticipant(member: $0, context: context) }
            .compactMap(\.self)

        WireCallCenterCallParticipantNotification(conversationId: conversationId, participants: participants)
            .post(in: context.notificationContext)
    }

}

extension CallParticipantsSnapshot {

    // Remove duplicates see: https://wearezeta.atlassian.net/browse/ZIOS-8610
    private static func removeDuplicateMembers(_ members: [AVSCallMember]) -> OrderedSetState<AVSCallMember> {
        let callMembers = members.reduce([AVSCallMember]()) { (filtered, member) in
            filtered + (filtered.contains(member) ? [] : [member])
        }

        return callMembers.toOrderedSetState()
    }
}
