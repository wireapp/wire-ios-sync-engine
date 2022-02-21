//
// Wire
// Copyright (C) 2016 Wire Swiss GmbH
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
import WireRequestStrategy
import WireDataModel

@objcMembers
public final class CallingRequestStrategy: AbstractRequestStrategy, ZMSingleRequestTranscoder, ZMContextChangeTracker, ZMContextChangeTrackerSource, ZMEventConsumer, FederationAware {

    // MARK: - Private Properties

    private let zmLog = ZMSLog(tag: "calling")

    private let messageSync: ProteusMessageSync<GenericMessageEntity>
    private let flowManager: FlowManagerType
    private let decoder = JSONDecoder()

    private let callEventStatus: CallEventStatus

    private var callConfigRequestSync: ZMSingleRequestSync! = nil
    private var callConfigCompletion: CallConfigRequestCompletion?

    private var clientDiscoverySync: ZMSingleRequestSync! = nil
    private var clientDiscoveryRequest: ClientDiscoveryRequest?

    private let ephemeralURLSession = URLSession(configuration: .ephemeral)

    // MARK: - Internal Properties

    var callCenter: WireCallCenterV3?

    // MARK: - Public Properties

    public var useFederationEndpoint: Bool {
        get {
            messageSync.isFederationEndpointAvailable
        }
        set {
            messageSync.isFederationEndpointAvailable = newValue
        }
    }

    // MARK: - Init

    public init(managedObjectContext: NSManagedObjectContext,
                applicationStatus: ApplicationStatus,
                clientRegistrationDelegate: ClientRegistrationDelegate,
                flowManager: FlowManagerType,
                callEventStatus: CallEventStatus) {

        self.messageSync = ProteusMessageSync(context: managedObjectContext, applicationStatus: applicationStatus)
        self.flowManager = flowManager
        self.callEventStatus = callEventStatus

        super.init(withManagedObjectContext: managedObjectContext, applicationStatus: applicationStatus)

        configuration = [.allowsRequestsWhileInBackground,
                         .allowsRequestsWhileOnline,
                         .allowsRequestsWhileWaitingForWebsocket]

        callConfigRequestSync = ZMSingleRequestSync(singleRequestTranscoder: self, groupQueue: managedObjectContext)
        clientDiscoverySync = ZMSingleRequestSync(singleRequestTranscoder: self, groupQueue: managedObjectContext)

        let selfUser = ZMUser.selfUser(in: managedObjectContext)

        if let clientId = selfUser.selfClient()?.remoteIdentifier {
            zmLog.debug("Creating callCenter from init")
            callCenter = WireCallCenterV3Factory.callCenter(withUserId: selfUser.avsIdentifier,
                                                            clientId: clientId,
                                                            uiMOC: managedObjectContext.zm_userInterface,
                                                            flowManager: flowManager,
                                                            analytics: managedObjectContext.analytics,
                                                            transport: self)
        }
    }

    // MARK: - Methods

    public override func nextRequestIfAllowed() -> ZMTransportRequest? {
        let request = callConfigRequestSync.nextRequest() ??
                      clientDiscoverySync.nextRequest() ??
                      messageSync.nextRequest()

        request?.forceToVoipSession()
        return request
    }

    public func dropPendingCallMessages(for conversation: ZMConversation) {
        messageSync.expireMessages(withDependency: conversation)
    }

// MARK: - Single Request Transcoder

    public func request(for sync: ZMSingleRequestSync) -> ZMTransportRequest? {
        switch sync {
        case callConfigRequestSync:
            zmLog.debug("Scheduling request to '/calls/config/v2'")

            return ZMTransportRequest(path: "/calls/config/v2",
                                      method: .methodGET,
                                      binaryData: nil,
                                      type: "application/json",
                                      contentDisposition: nil,
                                      shouldCompress: true)

        case clientDiscoverySync:
            guard
                let request = clientDiscoveryRequest,
                let selfClient = ZMUser.selfUser(in: managedObjectContext).selfClient()
            else {
                return nil
            }

            zmLog.debug("Scheduling request to discover clients")

            let factory = ClientMessageRequestFactory()

            if useFederationEndpoint {
                guard let domain = request.domain else {
                    zmLog.error("Could not create request: missing domain")
                    return nil
                }

                return factory.upstreamRequestForFetchingClients(conversationId: request.conversationId,
                                                                 domain: domain,
                                                                 selfClient: selfClient)
            } else {
                return factory.upstreamRequestForFetchingClients(conversationId: request.conversationId,
                                                                 selfClient: selfClient)
            }

        default:
            return nil
        }

    }

    public func didReceive(_ response: ZMTransportResponse, forSingleRequest sync: ZMSingleRequestSync) {
        switch sync {
        case callConfigRequestSync:
            zmLog.debug("Received call config response for \(self): \(response)")
            if response.httpStatus == 200 {
                var payloadAsString: String?
                if let payload = response.payload, let data = try? JSONSerialization.data(withJSONObject: payload, options: []) {
                    payloadAsString = String(data: data, encoding: .utf8)
                }
                zmLog.debug("Callback: \(String(describing: self.callConfigCompletion))")
                self.callConfigCompletion?(payloadAsString, response.httpStatus)
                self.callConfigCompletion = nil
            }

        case clientDiscoverySync:
            zmLog.debug("Received client discovery response for \(self): \(response)")

            defer {
                clientDiscoveryRequest = nil
            }

            guard response.httpStatus == 412 else {
                zmLog.warn("Expected 412 response: missing clients")
                return
            }

            guard let jsonData = response.rawData else { return }

            do {
                var clients = [AVSClient]()

                if useFederationEndpoint {
                    clients = try decodeFederatedClientDiscovery(jsonData: jsonData)
                } else {
                    clients = try decodeClientDiscovery(jsonData: jsonData)
                }

                clientDiscoveryRequest?.completion(clients)
            } catch {
                zmLog.error("Could not parse client discovery response: \(error.localizedDescription)")
            }

        default:
            break
        }
    }

    private func decodeClientDiscovery(jsonData: Data) throws -> [AVSClient] {
        let payload = try decoder.decode(ClientDiscoveryResponsePayload.self, from: jsonData)

        return payload.clients
    }

    private func decodeFederatedClientDiscovery(jsonData: Data) throws -> [AVSClient] {
        let payload = try decoder.decode(FederatedClientDiscoveryResponsePayload.self, from: jsonData)

        return payload.clients
    }

    // MARK: - Context Change Tracker

    public var contextChangeTrackers: [ZMContextChangeTracker] {
        return [self] + messageSync.contextChangeTrackers
    }

    public func fetchRequestForTrackedObjects() -> NSFetchRequest<NSFetchRequestResult>? {
        return nil
    }

    public func addTrackedObjects(_ objects: Set<NSManagedObject>) {
        // nop
    }

    public func objectsDidChange(_ objects: Set<NSManagedObject>) {
        guard callCenter == nil else { return }

        for object in objects {
            if let userClient = object as? UserClient, userClient.isSelfClient(), let clientId = userClient.remoteIdentifier, let userId = userClient.user?.avsIdentifier {
                zmLog.debug("Creating callCenter")
                let uiContext = managedObjectContext.zm_userInterface!
                let analytics = managedObjectContext.analytics
                uiContext.performGroupedBlock {
                    self.callCenter = WireCallCenterV3Factory.callCenter(withUserId: userId,
                                                                         clientId: clientId,
                                                                         uiMOC: uiContext.zm_userInterface,
                                                                         flowManager: self.flowManager,
                                                                         analytics: analytics,
                                                                         transport: self)
                }
                break
            }
        }
    }

    // MARK: - Event Consumer

    public func processEventsWhileInBackground(_ events: [ZMUpdateEvent]) {
        let serverTimeDelta = managedObjectContext.serverTimeDelta

        for event in events {
            guard event.type == .conversationOtrMessageAdd else { continue }

            if let genericMessage = GenericMessage(from: event), genericMessage.hasCalling {

                guard
                    let payload = genericMessage.calling.content.data(using: .utf8, allowLossyConversion: false),
                    let senderUUID = event.senderUUID,
                    let conversationUUID = event.conversationUUID,
                    let clientId = event.senderClientID,
                    let eventTimestamp = event.timestamp
                else {
                    zmLog.error("ignoring calling message: \(genericMessage.debugDescription)")
                    continue
                }

                self.zmLog.debug("received calling message, timestamp \(eventTimestamp), serverTimeDelta \(serverTimeDelta)")

                let isRemoteMute = CallEventContent(from: payload, with: decoder)?.isRemoteMute ?? false

                guard !isRemoteMute else {
                    callCenter?.muted = true
                    zmLog.debug("muted remotely from calling message")
                    return
                }

                processCallEvent(
                    conversationUUID: conversationUUID,
                    senderUUID: senderUUID,
                    clientId: clientId,
                    event: event,
                    payload: payload,
                    currentTimestamp: Date().addingTimeInterval(serverTimeDelta),
                    eventTimestamp: eventTimestamp
                )
            }
        }
    }

    private func processCallEvent(conversationUUID: UUID,
                                  senderUUID: UUID,
                                  clientId: String,
                                  event: ZMUpdateEvent,
                                  payload: Data,
                                  currentTimestamp: Date,
                                  eventTimestamp: Date) {
        let conversationId = AVSIdentifier(
            identifier: conversationUUID,
            domain: useFederationEndpoint ? event.conversationDomain : nil
        )
        let userId = AVSIdentifier(
            identifier: senderUUID,
            domain: useFederationEndpoint ? event.senderDomain : nil
        )

        let callEvent = CallEvent(
            data: payload,
            currentTimestamp: currentTimestamp,
            serverTimestamp: eventTimestamp,
            conversationId: conversationId,
            userId: userId,
            clientId: clientId
        )

        callEventStatus.scheduledCallEventForProcessing()

        callCenter?.processCallEvent(callEvent, completionHandler: { [weak self] in
            self?.zmLog.debug("processed calling message")
            self?.callEventStatus.finishedProcessingCallEvent()
        })
    }

    public func processEvents(_ events: [ZMUpdateEvent], liveEvents: Bool, prefetchResult: ZMFetchRequestBatchResult?) {
        // No op
    }

}

// MARK: - Wire Call Center Transport

extension CallingRequestStrategy: WireCallCenterTransport {

    public func send(data: Data, conversationId: AVSIdentifier, targets: [AVSClient]?, completionHandler: @escaping ((Int) -> Void)) {

        guard let dataString = String(data: data, encoding: .utf8) else {
            zmLog.error("Not sending calling messsage since it's not UTF-8")
            completionHandler(500)
            return
        }

        managedObjectContext.performGroupedBlock {
            guard let conversation = ZMConversation.fetch(with: conversationId.identifier,
                                                          domain: conversationId.domain,
                                                          in: self.managedObjectContext)
            else {
                self.zmLog.error("Not sending calling messsage since conversation doesn't exist")
                completionHandler(500)
                return
            }

            self.zmLog.debug("schedule calling message")

            let genericMessage = GenericMessage(content: Calling(content: dataString))
            let recipients = targets.map { self.recipients(for: $0, in: self.managedObjectContext) } ?? .conversationParticipants
            let message = GenericMessageEntity(conversation: conversation,
                                               message: genericMessage,
                                               targetRecipients: recipients,
                                               completionHandler: nil)

            self.messageSync.sync(message) { (result, response) in
                if case .success = result {
                    completionHandler(response.httpStatus)
                }
            }
        }
    }

    public func sendSFT(data: Data, url: URL, completionHandler: @escaping ((Result<Data>) -> Void)) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = data

        ephemeralURLSession.task(with: request) { data, response, error in
            if let error = error {
                completionHandler(.failure(SFTResponseError.transport(error: error)))
                return
            }

            guard
                let response = response as? HTTPURLResponse,
                let data = data
            else {
                completionHandler(.failure(SFTResponseError.missingData))
                return
            }

            guard (200...299).contains(response.statusCode) else {
                completionHandler(.failure(SFTResponseError.server(status: response.statusCode)))
                return
            }

            completionHandler(.success(data))
        }.resume()
    }

    public func requestCallConfig(completionHandler: @escaping CallConfigRequestCompletion) {
        self.zmLog.debug("requestCallConfig() called, moc = \(managedObjectContext)")
        managedObjectContext.performGroupedBlock { [unowned self] in
            self.zmLog.debug("requestCallConfig() on the moc queue")
            self.callConfigCompletion = completionHandler

            self.callConfigRequestSync.readyForNextRequestIfNotBusy()
            RequestAvailableNotification.notifyNewRequestsAvailable(nil)
        }
    }

    public func requestClientsList(conversationId: AVSIdentifier, completionHandler: @escaping ([AVSClient]) -> Void) {
        self.zmLog.debug("requestClientList() called, moc = \(managedObjectContext)")
        managedObjectContext.performGroupedBlock { [unowned self] in
            self.clientDiscoveryRequest = ClientDiscoveryRequest(
                conversationId: conversationId.identifier,
                domain: conversationId.domain,
                completion: completionHandler
            )
            self.clientDiscoverySync.readyForNextRequestIfNotBusy()
            RequestAvailableNotification.notifyNewRequestsAvailable(nil)
        }
    }

    enum SFTResponseError: LocalizedError {

        case server(status: Int)
        case transport(error: Error)
        case missingData

        var errorDescription: String? {
            switch self {
            case let .server(status: status):
                return "Server http status code: \(status)"
            case let .transport(error: error):
                return "Transport error: \(error.localizedDescription)"
            case .missingData:
                return "Response body missing data"
            }
        }

    }

    private func recipients(for targets: [AVSClient], in managedObjectContext: NSManagedObjectContext) -> GenericMessageEntity.Recipients {
        let clientsByUser = targets
            .compactMap { UserClient.fetchExistingUserClient(with: $0.clientId, in: managedObjectContext) }
            .partition(by: \.user)
            .mapValues { Set($0) }

        return .clients(clientsByUser)
    }

}

// MARK: - Client Discovery Request

extension CallingRequestStrategy {

    struct ClientDiscoveryRequest {

        let conversationId: UUID
        let domain: String?
        let completion: ([AVSClient]) -> Void

    }

    struct FederatedClientDiscoveryResponsePayload: Decodable {
        let clients: [AVSClient]

        init(from decoder: Decoder) throws {
            var allClients = [AVSClient]()
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let domainsContainer = try container.nestedContainer(keyedBy: DynamicKey.self, forKey: .missing)

            try domainsContainer.allKeys.forEach { domainKey in
                var domainClients = [AVSClient]()
                let usersContainer = try domainsContainer.nestedContainer(keyedBy: DynamicKey.self, forKey: domainKey)

                try usersContainer.allKeys.forEach { userIdKey in
                    let clientIds = try usersContainer.decode([String].self, forKey: userIdKey)

                    let identifier = AVSIdentifier(
                        identifier: UUID(uuidString: userIdKey.stringValue)!,
                        domain: domainKey.stringValue
                    )

                    domainClients += clientIds.compactMap {
                        AVSClient(userId: identifier, clientId: $0)
                    }
                }

                allClients += domainClients
            }

            clients = allClients
        }

        enum CodingKeys: String, CodingKey {
            case missing
        }
    }

    struct ClientDiscoveryResponsePayload: Decodable {

        let clients: [AVSClient]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let nestedContainer = try container.nestedContainer(keyedBy: DynamicKey.self, forKey: .missing)

            var allClients = [AVSClient]()

            try nestedContainer.allKeys.forEach { userIdKey in
                let clientIds = try nestedContainer.decode([String].self, forKey: userIdKey)

                let identifier = AVSIdentifier(
                    identifier: UUID(uuidString: userIdKey.stringValue)!,
                    domain: nil
                )

                allClients += clientIds.compactMap {
                    AVSClient(userId: identifier, clientId: $0)
                }
            }

            clients = allClients
        }

        enum CodingKeys: String, CodingKey {

            case missing

        }
    }

    struct DynamicKey: CodingKey {
        var stringValue: String

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        var intValue: Int?

        init?(intValue: Int) {
            return nil
        }
    }
}
