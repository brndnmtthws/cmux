import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import OSLog
import Testing

/// Lawrence 2026-10-23: "spamming a bunch of cmd shift d and cmd d etc is laggy ish". Every split
/// press in a burst shows its pane in the key's turn and the daemon makes every one of them: a press
/// on a pane still being created (its stand-in) splits that pane, never a pane the daemon does not
/// know. Runs the app's Split Right against a same-tree cmux-tui daemon.
/// The refusals the app showed while a test ran.
@MainActor private final class SeenRefusals {
    var reasons: [String] = []
}

@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SplitBurstTests {
    /// Cmd-D, then at once (same turn) Cmd-Shift-D on the pane it is creating: the second split goes to the
    /// daemon's pane for that stand-in, so both new panes stay. Before: the second command named the
    /// stand-in's handle, the daemon refused it, and its pane vanished (a lost press).
    @Test func cmdDOnAPaneStillBeingCreatedSplitsIt() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let content = try #require(services.windows.active?.workspaceContent)
            let before = Set(content.panes.keys)
            #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
            let creating = try #require(content.panes.first { !before.contains($0.key) }?.value, "the split showed no pane in its turn")
            #expect(creating.pane.tabs.allSatisfy { ProvisionalTab.isProvisional(surface: $0.surface) }, "the first split is still being created")
            let seen = SeenRefusals()
            let shown = services.registry.refusalObserver
            services.registry.refusalObserver = { reason, quiet in seen.reasons.append(reason); shown?(reason, quiet) }
            // Down, so the room check is the stand-in's height, not a third column's width.
            let standInAtPress = creating.pane.handle
            let onStandIn = ActionInvocation(target: ActionTargetRef(kind: .pane, id: creating.pane.id), origin: .user)
            var performed = false
            let work = services.registry.capturingWork { performed = services.registry.perform("splitDown", invocation: onStandIn) }
            #expect(performed)
            #expect(content.panes.count == before.count + 2, "the second split showed no pane in its turn; refusals \(seen.reasons)")
            @MainActor func confirmed() -> Int {
                content.panes.values.filter { $0.pane.tabs.contains { !ProvisionalTab.isProvisional(surface: $0.surface) } }.count
            }
            // The second split's own outcome: nil, or why it failed.
            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            let store = services.daemon.store
            let standIn = creating.pane.handle
            let diagnosis = "stand-in at press \(standInAtPress.rawValue); now \(standIn.rawValue); daemonHandle(showing:) \(String(describing: store.daemonHandle(showing: standInAtPress)?.rawValue)); "
                + "standInTargets \(store.standInTargets.map { "\($0.key.rawValue)->\($0.value)" }); "
                + "resource \(String(describing: creating.pane.resourceID?.rawValue)) -> \(String(describing: creating.pane.resourceID.flatMap { store.index.panesByResource[$0]?.handle.rawValue }))"
            #expect(failures.isEmpty, "the split of the stand-in failed: \(failures); \(diagnosis); the log: \(Self.rejections())")
            try await PinnedPageTests.until({ confirmed() == before.count + 2 && content.panes.count == before.count + 2 },
                                            report: { "\(content.panes.count) panes, \(confirmed()) made by the daemon; wanted \(before.count + 2); refusals \(seen.reasons)" })
            // And they stay: no refusal takes one back after its echo.
            try await Task.sleep(for: .milliseconds(300))
            #expect(content.panes.count == before.count + 2)
        }
    }

    /// This process's recent log lines about splits and rejected intents (the daemon's refusal text).
    private static func rejections() -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return ["no log store"] }
        let since = store.position(timeIntervalSinceLatestBoot: max(0, ProcessInfo.processInfo.systemUptime - 120))
        guard let entries = try? store.getEntries(at: since) else { return ["no entries"] }
        return Array(entries.compactMap { $0 as? OSLogEntryLog }.map(\.composedMessage)
            .filter { $0.contains("rejected") || $0.contains("split") }.suffix(8))
    }
}
