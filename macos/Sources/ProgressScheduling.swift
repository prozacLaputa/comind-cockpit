import Foundation

/// Scheduling metadata only. No conversation or note content is copied here.
struct ProgressSchedule: Codable, Equatable {
    var changedAt: Date? = nil
    var lastAttempt: Date? = nil
}

struct ProgressReviewPolicy {
    var quietPeriod: TimeInterval = 600
    var minimumInterval: TimeInterval = 1800
    func due(_ state: ProgressSchedule, previous: Date?) -> Date? {
        guard let changed = state.changedAt else { return nil }
        let last = [state.lastAttempt, previous].compactMap { $0 }.max()
        return max(changed.addingTimeInterval(quietPeriod), last?.addingTimeInterval(minimumInterval) ?? .distantPast)
    }
}

extension AppStore {
    func resumeProgressSchedules() {
        for id in progressSchedules.keys where progressSchedules[id]?.changedAt != nil && employeeProfile(for: id).autoReview {
            startProgressWorker(id)
        }
    }
    func requestReview(_ id: String, automatically: Bool = false) {
        guard canEdit, areas.contains(where: { $0.id == id }), !automatically || employeeProfile(for: id).autoReview else { return }
        if automatically {
            progressSchedules[id, default: .init()].changedAt = Date()
            persist()
            guard storageWarning == nil else { return }
        } else {
            reviewRequests[id] = true
            // A deliberate click bypasses the pending timer, not an in-flight model request.
            if !reviewingAreas.contains(id) { reviewTasks.removeValue(forKey: id)?.cancel() }
        }
        startProgressWorker(id)
    }
    func startProgressWorker(_ id: String) {
        guard canEdit, areas.contains(where: { $0.id == id }), reviewTasks[id] == nil else { return }
        let token = UUID()
        reviewWorkerIDs[id] = token
        reviewTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.reviewWorkerIDs[id] == token {
                    self.reviewTasks.removeValue(forKey: id)
                    self.reviewRequests.removeValue(forKey: id)
                    self.reviewWorkerIDs.removeValue(forKey: id)
                }
            }
            while !Task.isCancelled, self.canEdit, self.areas.contains(where: { $0.id == id }) {
                let manual = self.reviewRequests[id] == true
                if !manual {
                    guard self.employeeProfile(for: id).autoReview,
                          let due = self.progressPolicy.due(self.progressSchedules[id] ?? .init(), previous: self.progressReports[id]?.generatedAt) else { return }
                    let delay = due.timeIntervalSinceNow
                    if delay > 0 {
                        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                        continue // New turns may have moved the deadline while asleep.
                    }
                    if let running = self.codex.runningThreadID, self.threadLinks.contains(where: { $0.areaID == id && $0.threadID == running }) {
                        self.progressSchedules[id, default: .init()].changedAt = Date()
                        self.persist()
                        continue
                    }
                }
                self.reviewRequests.removeValue(forKey: id)
                self.progressSchedules[id] = .init(changedAt: nil, lastAttempt: Date())
                self.persist() // Record the attempt before calling a model, including failed attempts.
                guard self.storageWarning == nil else { return }
                await self.reviewArea(id)
                // No retry on failure. A genuinely new change or a manual click is required.
            }
        }
    }
}
