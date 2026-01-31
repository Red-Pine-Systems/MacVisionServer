import Foundation
import VisionCore

actor JobQueue {
    private let config: Config
    private var queue: [Job] = []
    private var inflight: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // Stats
    private(set) var totalProcessed: Int = 0
    private(set) var totalErrors: Int = 0
    private(set) var totalOverloaded: Int = 0

    struct Stats {
        let queueDepth: Int
        let inflight: Int
        let totalProcessed: Int
        let totalErrors: Int
        let totalOverloaded: Int
    }

    init(config: Config) {
        self.config = config
    }

    struct Job {
        let id: String
        let enqueuedAt: UInt64
        let continuation: CheckedContinuation<Result<Void, JobError>, Never>
    }

    enum JobError: Error {
        case queueFull
        case queueWaitTimeout
        case processingTimeout
    }

    func getStats() -> Stats {
        Stats(
            queueDepth: queue.count,
            inflight: inflight,
            totalProcessed: totalProcessed,
            totalErrors: totalErrors,
            totalOverloaded: totalOverloaded
        )
    }

    /// Attempt to enqueue a job. Returns immediately if queue is full or estimated wait is too long.
    func tryEnqueue(jobId: String) async -> Result<Void, JobError> {
        // Check if queue is full
        if queue.count >= config.maxQueue {
            totalOverloaded += 1
            return .failure(.queueFull)
        }

        // Estimate wait time based on current queue depth and inflight
        // Simple heuristic: assume each job takes ~500ms average
        let estimatedWaitMs = (queue.count * 500) / max(config.maxInflight, 1)
        if estimatedWaitMs > config.maxQueueWaitMs {
            totalOverloaded += 1
            return .failure(.queueWaitTimeout)
        }

        let enqueuedAt = nowNs()

        // Enqueue and wait for slot
        return await withCheckedContinuation { continuation in
            let job = Job(id: jobId, enqueuedAt: enqueuedAt, continuation: continuation)
            queue.append(job)
            processNextIfPossible()
        }
    }

    /// Called when a job finishes (success or error)
    func complete(success: Bool) {
        inflight -= 1
        if success {
            totalProcessed += 1
        } else {
            totalErrors += 1
        }
        processNextIfPossible()
    }

    private func processNextIfPossible() {
        while inflight < config.maxInflight && !queue.isEmpty {
            let job = queue.removeFirst()
            let waitedNs = nowNs() - job.enqueuedAt
            let waitedMs = Int(waitedNs / 1_000_000)

            if waitedMs > config.maxQueueWaitMs {
                // Job waited too long in queue
                totalOverloaded += 1
                job.continuation.resume(returning: .failure(.queueWaitTimeout))
                continue
            }

            inflight += 1
            job.continuation.resume(returning: .success(()))
        }
    }
}
