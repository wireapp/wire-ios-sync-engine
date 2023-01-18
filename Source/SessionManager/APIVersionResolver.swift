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
import WireTransport

final class APIVersionResolver {

    // MARK: - Properties

    weak var delegate: APIVersionResolverDelegate?

    let clientProdVersions: Set<APIVersion>
    let clientDevVersions: Set<APIVersion>
    let isDeveloperModeEnabled: Bool

    private let queue: ZMSGroupQueue = DispatchGroupQueue(queue: .main)
    private let transportSession: UnauthenticatedTransportSessionProtocol

    // MARK: - Life cycle

    init(
        clientProdVersions: Set<APIVersion> = APIVersion.productionVersions,
        clientDevVersions: Set<APIVersion> = APIVersion.developmentVersions,
        transportSession: UnauthenticatedTransportSessionProtocol,
        isDeveloperModeEnabled: Bool
    ) {
        self.clientProdVersions = clientProdVersions
        self.clientDevVersions = clientDevVersions
        self.transportSession = transportSession
        self.isDeveloperModeEnabled = isDeveloperModeEnabled
    }

    // MARK: - Methods

    func resolveAPIVersion(completion: @escaping (Error?) -> Void = { _ in }) {
        // TODO: check if it's been 24hours and proceed or not
        sendRequest(completion: completion)
    }

    private func sendRequest(completion: @escaping (Error?) -> Void = {_ in }) {
        // This is endpoint isn't versioned, so it always version 0.
        let request = ZMTransportRequest(getFromPath: "/api-version", apiVersion: APIVersion.v0.rawValue)
        let completionHandler = ZMCompletionHandler(on: queue) { [weak self] response in
            self?.handleResponse(response)
            completion(response.transportSessionError)
        }

        request.add(completionHandler)
        transportSession.enqueueOneTime(request)

    }

    private func handleResponse(_ response: ZMTransportResponse) {
        guard response.result == .success else {
            BackendInfo.apiVersion = .v0
            BackendInfo.domain = "wire.com"
            BackendInfo.isFederationEnabled = false
            return
        }

        guard
            let data = response.rawData,
            let payload = APIVersionResponsePayload(data)
        else {
            fatalError()
        }

        let backendProdVersions = Set(payload.supported.compactMap(APIVersion.init(rawValue:)))
        let backendDevVersions = Set(payload.development?.compactMap(APIVersion.init(rawValue:)) ?? [])
        let allBackendVersions = backendProdVersions.union(backendDevVersions)

        let commonProductionVersions = backendProdVersions.intersection(clientProdVersions)

        if commonProductionVersions.isEmpty {
            reportBlacklist(payload: payload)
            BackendInfo.apiVersion = nil
        } else if
            isDeveloperModeEnabled,
            let preferredAPIVersion = BackendInfo.preferredAPIVersion,
            allBackendVersions.contains(preferredAPIVersion)
        {
            BackendInfo.apiVersion = preferredAPIVersion
        } else {
            BackendInfo.apiVersion = commonProductionVersions.max()
        }

        BackendInfo.domain = payload.domain

        let wasFederationEnabled = BackendInfo.isFederationEnabled
        BackendInfo.isFederationEnabled = payload.federation

        if !wasFederationEnabled && BackendInfo.isFederationEnabled {
            delegate?.apiVersionResolverDetectedFederationHasBeenEnabled()
        }

        if let apiVersion = BackendInfo.apiVersion {
            delegate?.apiVersionResolverDidResolve(apiVersion: apiVersion)
        }
    }

    private func reportBlacklist(payload: APIVersionResponsePayload) {
        guard let maxBackendVersion = payload.supported.max() else {
            blacklistApp(reason: .backendAPIVersionObsolete)
            return
        }

        guard let minClientVersion = clientProdVersions.min()?.rawValue else {
            blacklistApp(reason: .clientAPIVersionObsolete)
            return
        }

        if maxBackendVersion < minClientVersion {
            blacklistApp(reason: .backendAPIVersionObsolete)
        } else {
            blacklistApp(reason: .clientAPIVersionObsolete)
        }
    }

    private func blacklistApp(reason: BlacklistReason) {
        delegate?.apiVersionResolverFailedToResolveVersion(reason: reason)
    }

    private struct APIVersionResponsePayload: Decodable {

        let supported: [Int32]
        let development: [Int32]?
        let federation: Bool
        let domain: String

    }

}

// MARK: - Delegate

protocol APIVersionResolverDelegate: AnyObject {

    func apiVersionResolverDetectedFederationHasBeenEnabled()
    func apiVersionResolverFailedToResolveVersion(reason: BlacklistReason)
    func apiVersionResolverDidResolve(apiVersion: APIVersion)

}

// MARK: - Prod/Dev versions

public extension APIVersion {

    /// API versions considered production ready by the client.
    ///
    /// IMPORTANT: A version X should only be considered a production version
    /// if the backend also considers X production ready (i.e no more changes
    /// can be made to the API of X) and the implementation of X is correct
    /// and tested.
    ///
    /// Only if these critera are met should we explicitly mark the version
    /// as production ready.

    static let productionVersions: Set<Self> = [.v0, .v1, .v2]

    /// API versions currently under development and not suitable for production
    /// environments.

    static let developmentVersions: Set<Self> = Set(allCases).subtracting(productionVersions)

}
