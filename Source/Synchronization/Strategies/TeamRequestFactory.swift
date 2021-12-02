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

final public class TeamDownloadRequestFactory {

    public static var teamPath: String {
        return "/teams"
    }

    public static func getRequest(for identifiers: UUID...) -> ZMTransportRequest {
        let ids = identifiers.map { $0.transportString() }.joined(separator: ",")
        return ZMTransportRequest(getFromPath: teamPath + "/" + ids)
    }

    public static func requestToDownloadRoles(for identifier: UUID) -> ZMTransportRequest {
        return ZMTransportRequest(getFromPath: teamPath + "/" + identifier.transportString() + "/conversations/roles")
    }

    public static var getTeamsRequest: ZMTransportRequest {
        return ZMTransportRequest(getFromPath: teamPath)
    }

    public static func getSingleMemberRequest(for identifier: UUID, in teamIdentifier: UUID) -> ZMTransportRequest {
        let path = teamPath + "/" + teamIdentifier.transportString() + "/members/" + identifier.transportString()
        return ZMTransportRequest(getFromPath: path)
    }

}
