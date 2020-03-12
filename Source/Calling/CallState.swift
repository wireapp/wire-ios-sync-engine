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
import avs

private let zmLog = ZMSLog(tag: "calling")

/**
 * A participant in the call.
 */

public struct CallParticipant: Hashable {
    
    public let user: ZMUser
    public let state: CallParticipantState

    public init(user: ZMUser, state: CallParticipantState) {
        self.user = user
        self.state = state
    }

    init?(member: AVSCallMember, context: NSManagedObjectContext) {
        guard let user = ZMUser(remoteID: member.remoteId, createIfNeeded: false, in: context) else { return nil }
        self.init(user: user, state: member.callParticipantState)
    }

    // MARK: - Computed Properties

    private var clientId: String? {
        switch state {
        case .connected(_, let clientId): return clientId
        default: return nil
        }
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(user.remoteIdentifier)
        hasher.combine(clientId)
    }

}


/**
 * The state of a participant in a call.
 */

public enum CallParticipantState: Equatable {
    /// Participant is not in the call
    case unconnected
    /// A network problem occured but the call may still connect
    case unconnectedButMayConnect
    /// Participant is in the process of connecting to the call
    case connecting
    /// Participant is connected to the call and audio is flowing
    case connected(videoState: VideoState, clientId: String)
}


/**
 * The audio state of a participant in a call.
 */

public enum AudioState: Int32, Codable {
    /// Audio is in the process of connecting.
    case connecting = 0
    /// Audio has been established and is flowing.
    case established = 1
    /// No relay candidate, though audio may still connect.
    case networkProblem = 2
}


/**
 * The state of video in the call.
 */

public enum VideoState: Int32, Codable {
    /// Sender is not sending video
    case stopped = 0
    /// Sender is sending video
    case started = 1
    /// Sender is sending video but currently has a bad connection
    case badConnection = 2
    /// Sender has paused the video
    case paused = 3
    /// Sender is sending a video of his/her desktop
    case screenSharing = 4
}

/**
 * The current state of a call.
 */

public enum CallState: Equatable {

    /// There's no call
    case none
    /// Outgoing call is pending
    case outgoing(degraded: Bool)
    /// Incoming call is pending
    case incoming(video: Bool, shouldRing: Bool, degraded: Bool)
    /// Call is answered
    case answered(degraded: Bool)
    /// Call is established (data is flowing)
    case establishedDataChannel
    /// Call is established (media is flowing)
    case established
    /// Call is over and audio/video is guranteed to be stopped
    case mediaStopped
    /// Call in process of being terminated
    case terminating(reason: CallClosedReason)
    /// Unknown call state
    case unknown

    /**
     * Logs the current state to the calling logs.
     */

    func logState() {
        switch self {
        case .answered(degraded: let degraded):
            zmLog.debug("answered call, degraded: \(degraded)")
        case .incoming(video: let isVideo, shouldRing: let shouldRing, degraded: let degraded):
            zmLog.debug("incoming call, isVideo: \(isVideo), shouldRing: \(shouldRing), degraded: \(degraded)")
        case .establishedDataChannel:
            zmLog.debug("established data channel")
        case .established:
            zmLog.debug("established call")
        case .outgoing(degraded: let degraded):
            zmLog.debug("outgoing call, , degraded: \(degraded)")
        case .terminating(reason: let reason):
            zmLog.debug("terminating call reason: \(reason)")
        case .mediaStopped:
            zmLog.debug("media stopped")
        case .none:
            zmLog.debug("no call")
        case .unknown:
            zmLog.debug("unknown call state")
        }
    }

    /**
     * Updates the state of the call when the security level changes.
     * - parameter securityLevel: The new security level of the conversation for the call.
     * - returns: The current status, updated with the appropriate degradation information.
     */

    func update(withSecurityLevel securityLevel: ZMConversationSecurityLevel) -> CallState {
        let degraded = securityLevel == .secureWithIgnored

        switch self {
        case .incoming(video: let video, shouldRing: let shouldRing, degraded: _):
            return .incoming(video: video, shouldRing: shouldRing, degraded: degraded)
        case .outgoing:
            return .outgoing(degraded: degraded)
        case .answered:
            return .answered(degraded: degraded)
        default:
            return self
        }
    }
}
