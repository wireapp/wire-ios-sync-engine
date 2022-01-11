//
// Wire
// Copyright (C) 2020 Wire Swiss GmbH
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

// Get FeatureFlags
public final class FeatureFlagRequestStrategy: AbstractRequestStrategy, ZMSingleRequestTranscoder {

    // MARK: - Private Property
    private let syncContext: NSManagedObjectContext
    private let syncStatus: SyncStatus

    private var needsFeatureFlagsRefresh: Bool {
        guard let thresholdDate = calculateDigitalSignatureFlagRefreshDate() else {
            return true
        }
        let now = Date()
        return now > thresholdDate
    }

    // MARK: - Public Property
    var singleRequestSync: ZMSingleRequestSync?

    // MARK: - AbstractRequestStrategy
    @objc
    public init(withManagedObjectContext managedObjectContext: NSManagedObjectContext,
                applicationStatus: ApplicationStatus,
                syncStatus: SyncStatus) {
        syncContext = managedObjectContext
        self.syncStatus = syncStatus

        super.init(withManagedObjectContext: managedObjectContext,
                   applicationStatus: applicationStatus)

        self.configuration = [.allowsRequestsDuringSlowSync,
                              .allowsRequestsWhileOnline]
        self.singleRequestSync = ZMSingleRequestSync(singleRequestTranscoder: self,
                                                     groupQueue: managedObjectContext)
    }

    @objc
    public override func nextRequestIfAllowed() -> ZMTransportRequest? {
        guard
            syncStatus.currentSyncPhase == .fetchingFeatureFlags || needsFeatureFlagsRefresh,
            let singleRequestSync = singleRequestSync
        else {
            return nil
        }

        singleRequestSync.readyForNextRequestIfNotBusy()
        return singleRequestSync.nextRequest()
    }

    // MARK: - ZMSingleRequestTranscoder

    public func request(for sync: ZMSingleRequestSync) -> ZMTransportRequest? {
        switch sync {
        case singleRequestSync:
            return makeDigitalSignatureFlagRequest()
        default:
            return nil
        }
    }

    public func didReceive(_ response: ZMTransportResponse,
                           forSingleRequest sync: ZMSingleRequestSync) {

        guard response.result == .permanentError || response.result == .success else {
            saveInitialDigitalSignatureFlag()
            return
        }

        if response.result == .success, let rawData = response.rawData {
            processDigitalSignatureFlagSuccess(with: rawData)
        }

        if syncStatus.currentSyncPhase == .fetchingFeatureFlags {
            syncStatus.finishCurrentSyncPhase(phase: .fetchingFeatureFlags)
        }
    }

    // MARK: - Helpers
    private func makeDigitalSignatureFlagRequest() -> ZMTransportRequest? {
        guard let teamId = ZMUser.selfUser(in: syncContext).teamIdentifier?.uuidString else {
            // Skip sync phase if the user doesn't belong to a team
            if syncStatus.currentSyncPhase == .fetchingFeatureFlags {
                syncStatus.finishCurrentSyncPhase(phase: .fetchingFeatureFlags)
            }
            return nil
        }

        return ZMTransportRequest(path: "/teams/\(teamId)/features/digital-signatures",
                                  method: .methodGET,
                                  payload: nil)
    }

    private func processDigitalSignatureFlagSuccess(with data: Data?) {
        guard let responseData = data else {
            return
        }

        do {
            let decodedResponse = try JSONDecoder().decode(SignatureFeatureFlagResponse.self,
                                                           from: responseData)
            update(with: decodedResponse)
        } catch {
            Logging.network.debug("Failed to decode SignatureResponse with \(error)")
        }
    }

    private func update(with response: SignatureFeatureFlagResponse) {
        guard let team = ZMUser.selfUser(in: syncContext).team else {
            return
        }

        FeatureFlag.updateOrCreate(with: .digitalSignature,
                                  value: response.status,
                                  team: team,
                                  context: syncContext)
        syncContext.saveOrRollback()
    }

    private func calculateDigitalSignatureFlagRefreshDate() -> Date? {
        guard
            let team = ZMUser.selfUser(in: syncContext).team,
            let flag = team.fetchFeatureFlag(with: .digitalSignature)
        else {
            saveInitialDigitalSignatureFlag()
            return nil
        }

        let calendar = Calendar.current
        return calendar.date(byAdding: .day,
                             value: 1,
                             to: flag.updatedTimestamp)
    }

    private func saveInitialDigitalSignatureFlag() {
        if let teams = ZMUser.selfUser(in: syncContext).team {
            FeatureFlag.updateOrCreate(with: .digitalSignature,
                                       value: false,
                                       team: teams,
                                       context: syncContext)
            syncContext.saveOrRollback()
        }
    }
}

// MARK: - SignatureFeatureFlagResponse
public struct SignatureFeatureFlagResponse: Codable, Equatable {
    public let status: Bool

    public init(status: Bool) {
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let statusStr = try container.decodeIfPresent(String.self, forKey: .status)
        switch statusStr {
        case "enabled":
            status = true
        default:
            status = false
        }
    }
}
