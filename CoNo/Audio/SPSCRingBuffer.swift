// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 단일 생산자·단일 소비자(SPSC) lock-free 링 버퍼 (Float 샘플, 인터리브 여부는 호출자 책임).
// 오디오 IO 스레드에서 호출되므로 read/write 는 할당·락·시스템 콜이 없다.

import Synchronization

final class SPSCRingBuffer: @unchecked Sendable {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    // 누적 카운터 (wrap 하지 않음). 사용 가능량 = write - read.
    private let writeCount = Atomic<Int>(0)
    private let readCount = Atomic<Int>(0)

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
    }

    /// 소비자가 읽을 수 있는 샘플 수 (양쪽 스레드에서 호출 가능, 근사치).
    var availableToRead: Int {
        writeCount.load(ordering: .acquiring) - readCount.load(ordering: .acquiring)
    }

    /// 생산자 전용. 실제로 쓴 샘플 수를 돌려준다 (가득 차면 일부만).
    @discardableResult
    func write(_ source: UnsafePointer<Float>, count: Int) -> Int {
        let written = writeCount.load(ordering: .relaxed)
        let read = readCount.load(ordering: .acquiring)
        let n = min(count, capacity - (written - read))
        guard n > 0 else { return 0 }

        let start = written % capacity
        let first = min(n, capacity - start)
        (storage + start).update(from: source, count: first)
        if n > first {
            storage.update(from: source + first, count: n - first)
        }
        writeCount.store(written + n, ordering: .releasing)
        return n
    }

    /// 소비자 전용. 실제로 읽은 샘플 수를 돌려준다.
    @discardableResult
    func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let read = readCount.load(ordering: .relaxed)
        let written = writeCount.load(ordering: .acquiring)
        let n = min(count, written - read)
        guard n > 0 else { return 0 }

        let start = read % capacity
        let first = min(n, capacity - start)
        destination.update(from: storage + start, count: first)
        if n > first {
            (destination + first).update(from: storage, count: n - first)
        }
        readCount.store(read + n, ordering: .releasing)
        return n
    }
}
