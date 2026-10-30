import Darwin
import Testing
import os
import RofiCore

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
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        streamRows(
            fileDescriptor: fds[0],
            separator: separator,
            onRows: { continuation.yield(.rows($0.map(\.text))) },
            onEnd: {
                continuation.yield(.end)
                continuation.finish()
            }
        )
        return Reader(events: events, readEnd: fds[0], writeEnd: fds[1])
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
        // by the time "a" is delivered.
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
        let ends = OSAllocatedUnfairLock(initialState: 0)
        let (released, continuation) = AsyncStream.makeStream(of: Never.self)
        do {
            // Scoped so that only the reader's closure keeps the signal alive.
            let signal = ReleaseSignal { continuation.finish() }
            streamRows(
                fileDescriptor: fds[0],
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
