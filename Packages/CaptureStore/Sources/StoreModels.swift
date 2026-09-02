import CaptureCore
import DeliveryKit
import Foundation

public enum DeliveryState: String, Codable, CaseIterable, Hashable, Sendable {
    case queued
    case attempting
    case retryWait = "retry_wait"
    case delivered
    case pausedAuthentication = "paused_authentication"
    case failedPermanent = "failed_permanent"
}

public struct DeliveryJob: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let eventID: UUID
    public let destinationID: UUID
    public var state: DeliveryState
    public var attemptCount: Int
    public var nextAttemptAt: Date?
    public var leaseOwner: UUID?
    public var leaseExpiresAt: Date?
    public var lastHTTPStatus: Int?
    public var lastErrorCode: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        eventID: UUID,
        destinationID: UUID,
        state: DeliveryState = .queued,
        attemptCount: Int = 0,
        nextAttemptAt: Date? = nil,
        leaseOwner: UUID? = nil,
        leaseExpiresAt: Date? = nil,
        lastHTTPStatus: Int? = nil,
        lastErrorCode: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.eventID = eventID
        self.destinationID = destinationID
        self.state = state
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.leaseOwner = leaseOwner
        self.leaseExpiresAt = leaseExpiresAt
        self.lastHTTPStatus = lastHTTPStatus
        self.lastErrorCode = lastErrorCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct DeliveryEnvelope: Sendable {
    public let job: DeliveryJob
    public let event: CaptureEvent
    public let destination: Destination

    public init(job: DeliveryJob, event: CaptureEvent, destination: Destination) {
        self.job = job
        self.event = event
        self.destination = destination
    }
}

public struct QueueItem: Identifiable, Sendable {
    public var id: UUID { event.id }
    public let event: CaptureEvent
    public let deliveries: [DeliveryJob]

    public init(event: CaptureEvent, deliveries: [DeliveryJob]) {
        self.event = event
        self.deliveries = deliveries
    }
}

public struct ExportSnapshot: Codable, Sendable {
    public let exportVersion: Int
    public let exportedAt: Date
    public let events: [CaptureEvent]
    public let destinations: [Destination]
    public let deliveries: [DeliveryJob]

    public init(
        exportVersion: Int = 1,
        exportedAt: Date = Date(),
        events: [CaptureEvent],
        destinations: [Destination],
        deliveries: [DeliveryJob]
    ) {
        self.exportVersion = exportVersion
        self.exportedAt = exportedAt
        self.events = events
        self.destinations = destinations
        self.deliveries = deliveries
    }
}

public enum CaptureStoreError: Error, Equatable, Sendable {
    case eventIDConflict(UUID)
    case missingDestination(UUID)
    case corruptRecord(String)
}

