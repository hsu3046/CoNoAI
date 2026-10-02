// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Synchronization

/// 입력/출력 인스턴스별 observer 수명. 제거 전에 큐에 들어간 알림도 stop 뒤에는 무효다.
/// 등록 토큰은 소유 객체와 세대를 함께 구분해 새 장치와 같은 객체의 재시작을 모두 보호한다.
final class AudioConfigurationGate: Sendable {
    struct Registration: Sendable {
        fileprivate let owner: ObjectIdentifier
        fileprivate let generation: UInt64
    }

    private let generation = Atomic<UInt64>(0)

    func activate() -> Registration {
        Registration(owner: ObjectIdentifier(self), generation: generation.add(1, ordering: .acquiringAndReleasing).newValue)
    }

    func invalidate() { generation.add(1, ordering: .acquiringAndReleasing) }

    func isCurrent(_ registration: Registration) -> Bool {
        registration.owner == ObjectIdentifier(self) && generation.load(ordering: .acquiring) == registration.generation
    }

    /// NotificationCenter에 넘기는 실제 콜백. 시작 때 만들고, stop은 먼저 invalidate한다.
    func callback(_ action: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let registration = activate()
        return { [self] in
            guard isCurrent(registration) else { return }
            action()
        }
    }
}
