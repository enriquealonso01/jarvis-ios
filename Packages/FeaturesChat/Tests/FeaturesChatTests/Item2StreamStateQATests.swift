import Foundation
import XCTest

@testable import FeaturesChat

/// Item 2 TESTER QA — scope items 3 (coalescing) and 4 (stop semantics),
/// driven against the FeaturesChat stream-state surface.
///
/// Coalescing contract (plan §5.3): tokens may arrive one-by-one, but UI
/// commits happen at a coarse cadence — the FINAL text must be identical to
/// the un-coalesced reference (no token loss, no reordering), while commit
/// flushes stay far below one-per-token.
final class Item2StreamStateQATests: XCTestCase {

    // MARK: - Helpers

    /// A deterministic pseudo-token stream (word pieces + whitespace +
    /// unicode), stable across runs so coalesced vs reference compare exactly.
    private func makeTokens(_ count: Int) -> [String] {
        let pieces = ["Hel", "lo", " ", "wor", "ld", "!", " ", "—", " ", "ünïcode", " ", "tok", "3n", "\n"]
        return (0..<count).map { pieces[$0 % pieces.count] }
    }

    /// Un-coalesced reference: every token appended, one commit at the end.
    private func referenceText(_ tokens: [String]) -> String {
        var state = StreamState()
        state.begin()
        for t in tokens { state.append(token: t) }
        state.commitPending()
        return state.displayText
    }

    // MARK: 3. Coalescing: 1000 rapid tokens — fewer commits, identical text

    func testThousandTokensCoalesceWithIdenticalFinalText() {
        let tokens = makeTokens(1000)
        let expected = referenceText(tokens)

        var state = StreamState()
        state.begin()
        var appendCalls = 0
        var commitCalls = 0
        // Coalesced pipeline: append every token, flush at 50-token cadence
        // (the ingest actor's commit window stand-in) + one final flush.
        for t in tokens {
            state.append(token: t)
            appendCalls += 1
            if appendCalls % 50 == 0 {
                state.commitPending()
                commitCalls += 1
            }
        }
        state.commitPending() // tail flush
        commitCalls += 1

        XCTAssertEqual(state.displayText, expected,
                       "coalesced final text must equal the un-coalesced reference")
        XCTAssertEqual(appendCalls, 1000)
        XCTAssertLessThan(commitCalls, 100,
                          "commit flushes must be far below the token count (1000 → ≤20)")
        XCTAssertEqual(state.pendingText, "", "tail flush must leave nothing pending")
    }

    func testPerTokenCommitStillPreservesText() {
        // Degenerate coalescing (commit after EVERY token) must not corrupt
        // the text either — coalescing is an optimization, not a correctness
        // dependency.
        let tokens = makeTokens(250)
        var state = StreamState()
        state.begin()
        for t in tokens {
            state.append(token: t)
            state.commitPending()
        }
        XCTAssertEqual(state.displayText, referenceText(tokens))
    }

    func testIntermediateCommitsAreVisibleBeforeStreamEnd() {
        // Mid-stream reads (what the UI renders) see everything appended so
        // far — nothing is dropped between commit windows.
        var state = StreamState()
        state.begin()
        for t in makeTokens(120) { state.append(token: t) }
        let beforeCommit = state.displayText          // pending + committed
        state.commitPending()
        XCTAssertEqual(state.committedText, beforeCommit,
                       "commit must promote exactly the pending text")
        state.commitPending() // idempotent when nothing is pending
        XCTAssertEqual(state.committedText, beforeCommit)
    }

    // MARK: 4. Stop: freeze partial, ignore post-stop tokens

    func testStopMidStreamFreezesPartialText() {
        let tokens = makeTokens(100)
        var state = StreamState()
        state.begin()
        for t in tokens.prefix(37) { state.append(token: t) }
        XCTAssertTrue(state.isStreaming)

        state.stop()
        XCTAssertFalse(state.isStreaming, "stop must clear isStreaming")
        let frozen = state.displayText
        XCTAssertEqual(frozen, referenceText(Array(tokens.prefix(37))),
                       "stop must preserve every token received before it")
        XCTAssertEqual(state.pendingText, "", "stop flushes pending into committed")

        // Post-stop tokens are ignored — the message never resurrects.
        for t in tokens.suffix(20) { state.append(token: t) }
        XCTAssertEqual(state.displayText, frozen,
                       "appends after stop must be dropped")
    }

    func testStopFlushesPendingWindow() {
        // Stop landing mid-commit-window must not lose the unflushed tail.
        var state = StreamState()
        state.begin()
        state.append(token: "committed ")
        state.commitPending()
        state.append(token: "pending ")
        state.append(token: "tail")
        state.stop()
        XCTAssertEqual(state.committedText, "committed pending tail",
                       "stop must flush the pending window before freezing")
        XCTAssertFalse(state.isStreaming)
    }

    func testRestartAfterStopRequiresBegin() {
        // A stopped stream stays inert until an explicit begin(): the
        // resume-after-stop path cannot silently resurrect the old message.
        var state = StreamState()
        state.begin()
        state.append(token: "first")
        state.stop()
        let frozen = state.displayText

        state.append(token: "ghost")
        XCTAssertEqual(state.displayText, frozen)

        state.begin() // new turn → fresh pending, frozen text untouched
        XCTAssertTrue(state.isStreaming)
        XCTAssertEqual(state.committedText, frozen,
                       "begin() must not overwrite the previous committed text")
        state.append(token: "second")
        state.commitPending()
        XCTAssertEqual(state.displayText, frozen + "second")
    }
}
