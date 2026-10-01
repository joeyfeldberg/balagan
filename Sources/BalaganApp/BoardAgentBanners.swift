import AppKit
import Foundation
import BalaganCore

/// A desktop banner the app itself posts for an agent lifecycle transition (as opposed to one the
/// terminal escaped to us via libghostty's `DESKTOP_NOTIFICATION` / `RING_BELL`).
struct AgentBanner: Equatable {
    let title: String
    let body: String
    let taskID: TaskItem.ID
    let surfaceID: Surface.ID
}

/// App-posted agent banners: "waiting for your input" (delayed + re-validated) and "finished"
/// (immediate). The *decision* is `AgentAttentionPolicy` (pure, in Core); this file only supplies the
/// current facts and performs the effects.
///
/// Called from `setSurfaceLifecycle` — the one funnel every hook/reconciler transition passes
/// through — so a waiting agent surfaces identically however its state arrived.
extension BoardViewModel {
    /// The lifecycle facts the policy needs for a surface, right now.
    func agentAttentionContext(taskID: TaskItem.ID, surfaceID: Surface.ID) -> AgentAttentionPolicy.Context {
        AgentAttentionPolicy.Context(
            isViewedSurface: taskID == selectedTaskID && surfaceID == selectedSurfaceID,
            appIsFrontmost: appIsFrontmost(),
            isHibernated: hibernatedTaskIDs.contains(taskID),
            notificationsEnabled: agentNotificationsEnabled
        )
    }

    /// Applies the attention/banner policy for a lifecycle transition. Additive to
    /// `setSurfaceLifecycle`'s own "finished off-screen" flag (flagging is a set-insert, so the
    /// overlap is a no-op).
    func applyAgentAttentionPolicy(
        previous: AgentLifecycle?,
        next: AgentLifecycle?,
        taskID: TaskItem.ID,
        surfaceID: Surface.ID
    ) {
        // Any move away from "waiting" ends the episode: retire a banner that hasn't fired yet (the
        // agent unblocked itself, was answered, finished, or was slept) and forget that one was posted.
        if next != .needsInput {
            cancelWaitingBanner(taskID: taskID, surfaceID: surfaceID)
            postedWaitingBanners.remove(hostKey(taskID, surfaceID))
        }

        let outcome = AgentAttentionPolicy.evaluate(
            previous: previous,
            next: next,
            context: agentAttentionContext(taskID: taskID, surfaceID: surfaceID)
        )
        if outcome.flagsAttention {
            flagSurfaceNeedsAttention(taskID: taskID, surfaceID: surfaceID)
        }
        switch outcome.banner {
        case .waiting:
            scheduleWaitingBanner(taskID: taskID, surfaceID: surfaceID)
        case .finished:
            if AppPreferences.finishedBanners {
                postAgentBanner(makeBanner(taskID: taskID, surfaceID: surfaceID, kind: .finished))
            }
        case nil:
            break
        }
    }

    // MARK: - Waiting banner (delayed + re-validated)

    /// Holds a "waiting for your input" banner for `waitingBannerDelay`, then re-checks before firing.
    /// One pending banner per surface: a re-entered `needsInput` replaces the outstanding one.
    func scheduleWaitingBanner(taskID: TaskItem.ID, surfaceID: Surface.ID) {
        let key = hostKey(taskID, surfaceID)
        pendingWaitingBanners[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.deliverWaitingBanner(taskID: taskID, surfaceID: surfaceID)
        }
        pendingWaitingBanners[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + waitingBannerDelay, execute: work)
    }

    func cancelWaitingBanner(taskID: TaskItem.ID, surfaceID: Surface.ID) {
        pendingWaitingBanners.removeValue(forKey: hostKey(taskID, surfaceID))?.cancel()
    }

    /// Fires a pending waiting banner if the agent is *still* blocked and the user still isn't there.
    /// Exposed (not private) so tests can fire it without waiting out the delay.
    func deliverWaitingBanner(taskID: TaskItem.ID, surfaceID: Surface.ID) {
        let key = hostKey(taskID, surfaceID)
        pendingWaitingBanners.removeValue(forKey: key)
        guard AgentAttentionPolicy.shouldDeliverWaitingBanner(
            current: surfaceLifecycle[key],
            context: agentAttentionContext(taskID: taskID, surfaceID: surfaceID)
        ) else {
            return
        }
        postedWaitingBanners.insert(key)
        guard AppPreferences.waitingBanners else { return }
        postAgentBanner(makeBanner(taskID: taskID, surfaceID: surfaceID, kind: .waiting))
    }

    /// Re-arms the delayed waiting banner for every surface that is still blocked and that the user
    /// has just stopped looking at. Called when the selected task/surface changes and when Balagan
    /// resigns active. The first banner is normally armed by the transition itself and dropped at fire
    /// time because the user was looking — this is what catches "read the question, then walked off".
    func rearmWaitingBannersAfterFocusChange() {
        for (key, lifecycle) in surfaceLifecycle where lifecycle == .needsInput {
            guard pendingWaitingBanners[key] == nil else { continue }
            let context = agentAttentionContext(taskID: key.taskID, surfaceID: key.surfaceID)
            guard AgentAttentionPolicy.shouldRearmWaitingBanner(
                current: lifecycle,
                alreadyPosted: postedWaitingBanners.contains(key),
                context: context
            ) else { continue }
            scheduleWaitingBanner(taskID: key.taskID, surfaceID: key.surfaceID)
        }
    }

    // MARK: - Copy

    private func makeBanner(
        taskID: TaskItem.ID,
        surfaceID: Surface.ID,
        kind: AgentAttentionPolicy.Banner
    ) -> AgentBanner {
        let task = tasks.first { $0.id == taskID }
        let surface = task?.workspace.surfaces.first { $0.id == surfaceID }
        let agentName = surface?.resumeBinding?.agentName
        let title = task.map { $0.isProjectTerminals ? "\(projectName(for: $0.projectID)) — Terminals" : $0.title }
            ?? "Balagan"
        let body = kind == .waiting
            ? AgentAttentionPolicy.waitingBody(agentName: agentName)
            : AgentAttentionPolicy.finishedBody(agentName: agentName)
        return AgentBanner(title: title, body: body, taskID: taskID, surfaceID: surfaceID)
    }
}
