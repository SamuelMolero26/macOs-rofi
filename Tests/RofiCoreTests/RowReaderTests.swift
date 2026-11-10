import Darwin
import Dispatch
import RofiCore
import Testing
import os

// Contract: rofi's input thread, source/modes/dmenu.c:246-346. A broken reader
// shows up as a missing delivery, so the time limit turns that hang into a failure.
@Suite(.timeLimit(.minutes(1))) struct RowReaderTests {
    private enum Event: Equatable, Sendable {
        case rows([String])
        case end
    }

    private struct Reader {
        let events: AsyncStream<Event>
        let readEnd: Int32
        let writeEnd: Int32

        func send(_ text: String) {
            let bytes = Array(text.utf8)
            #expect(write(writeEnd, bytes, bytes.count) == bytes.count)
        }
    }

    /// Reports when the last closure holding it is released.
    private final class ReleaseSignal: Sendable {
        let onRelease: @Sendable () -> Void

        init(onRelease: @escaping @Sendable () -> Void) {
            self.onRelease = onRelease
        }

        deinit { onRelease() }
    }

    private func startReader(separator: UInt8 = 0x0A) -> Reader {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let readEnd = fds[0]
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        streamRows(
            open: { readEnd },
            separator: separator,
            onRows: { continuation.yield(.rows($0.map(\.text))) },
            onEnd: {
                continuation.yield(.end)
                continuation.finish()
            }
        )
        return Reader(events: events, readEnd: readEnd, writeEnd: fds[1])
    }

    @Test func aCompleteRowArrivesBeforeTheWriteEndCloses() async {
        let reader = startReader()
        var events = reader.events.makeAsyncIterator()

        reader.send("a\nb\n")
        let first = await events.next()
        #expect(first == .rows(["a", "b"]))

        close(reader.writeEnd)
        let last = await events.next()
        #expect(last == .end)
        close(reader.readEnd)
    }

    @Test func aPartialLineWaitsForItsSeparator() async {
        let reader = startReader()
        var events = reader.events.makeAsyncIterator()

        // One pipe write arrives in one read, so "par" has reached the splitter
        // by the time "a" is delivered; the rest follows well within 250 ms.
        reader.send("a\npar")
        let first = await events.next()
        #expect(first == .rows(["a"]))

        reader.send("tial\n")
        let second = await events.next()
        #expect(second == .rows(["partial"]))

        close(reader.writeEnd)
        let last = await events.next()
        #expect(last == .end)
        close(reader.readEnd)
    }

    @Test func aFinalUnterminatedRowArrivesAtEndOfInputBeforeTheEndSignal() async {
        let reader = startReader()
        var events = reader.events.makeAsyncIterator()

        reader.send("last")
        close(reader.writeEnd)

        let first = await events.next()
        #expect(first == .rows(["last"]))
        let second = await events.next()
        #expect(second == .end)
        close(reader.readEnd)
    }

    @Test func endIsSignaledOnceByTheTimeTheReaderLetsGoOfItsClosures() async {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let readEnd = fds[0]
        let ends = OSAllocatedUnfairLock(initialState: 0)
        let (released, continuation) = AsyncStream.makeStream(of: Never.self)
        do {
            // Scoped so that only the reader's closure keeps the signal alive.
            let signal = ReleaseSignal { continuation.finish() }
            streamRows(
                open: { readEnd },
                separator: 0x0A,
                onRows: { _ in },
                onEnd: { [signal] in
                    _ = signal
                    ends.withLock { $0 += 1 }
                }
            )
        }

        close(fds[1])
        for await _ in released {}

        #expect(ends.withLock { $0 } == 1)
        close(fds[0])
    }

    // A FIFO's open blocks until it has a writer, and the panel must not wait.
    @Test func streamRowsReturnsWhileItsOpenerIsStillBlocked() async {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let readEnd = fds[0]
        let gate = DispatchSemaphore(value: 0)
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        streamRows(
            // The bound keeps a synchronous opener from hanging the run: the
            // time limit cannot interrupt a thread blocked here. It then
            // opens nothing, so the row below never arrives.
            open: { gate.wait(timeout: .now() + 10) == .success ? readEnd : -1 },
            separator: 0x0A,
            onRows: { continuation.yield(.rows($0.map(\.text))) },
            onEnd: {
                continuation.yield(.end)
                continuation.finish()
            }
        )
        gate.signal()

        let bytes = Array("a\n".utf8)
        #expect(write(fds[1], bytes, bytes.count) == bytes.count)
        close(fds[1])

        var iterator = events.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == .rows(["a"]))
        let last = await iterator.next()
        #expect(last == .end)
        close(readEnd)
    }

    // rofi flushes a partial line after 250 ms, so a slow line becomes two
    // rows (source/modes/dmenu.c:275, 333-346). The one real wait in this
    // suite, generously longer than the flush.
    @Test func aPartialLineIsFlushedAfterAQuarterSecond() async throws {
        let reader = startReader()
        var events = reader.events.makeAsyncIterator()

        reader.send("par")
        try await Task.sleep(for: .seconds(1))
        reader.send("tial\n")

        let first = await events.next()
        #expect(first == .rows(["par"]))
        let second = await events.next()
        #expect(second == .rows(["tial"]))
        close(reader.writeEnd)
        let last = await events.next()
        #expect(last == .end)
        close(reader.readEnd)
    }

    @Test func aCustomSeparatorSplitsRows() async {
        let reader = startReader(separator: UInt8(ascii: "|"))
        var events = reader.events.makeAsyncIterator()

        reader.send("a\nb|c")
        let first = await events.next()
        #expect(first == .rows(["a\nb"]))

        close(reader.writeEnd)
        let second = await events.next()
        #expect(second == .rows(["c"]))
        let last = await events.next()
        #expect(last == .end)
        close(reader.readEnd)
    }
}
