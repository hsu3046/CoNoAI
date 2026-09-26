// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 캡처 대상(앱) 목록.
// 브라우저·Electron 앱은 소리를 메인 프로세스가 아니라 헬퍼 프로세스
// (Chrome Helper, Safari 의 com.apple.WebKit.GPU 등) 가 낸다. 그래서 HAL 오디오 프로세스를
// "책임 프로세스(responsible pid)" 기준으로 사용자 앱에 묶어서 앱 단위로 보여준다.

import AppKit
import AudioToolbox
import Observation

/// 사용자가 고르는 캡처 소스.
struct AudioSource: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// 특정 앱(과 그 헬퍼 프로세스들)
        case app(processObjectIDs: [AudioObjectID])
        /// 시스템 전체 — CoNo 자신은 제외 (제외 못 하면 피드백 루프라 시작 자체를 거부)
        case systemWide
    }

    let id: String
    let name: String
    let kind: Kind
    let bundleURL: URL?
    /// 앱 번들 ID (가사 연동 가능 여부 판단용). 시스템 전체면 nil
    var bundleID: String? = nil
    let isPlaying: Bool
}

@MainActor
@Observable
final class AudioSourceCatalog {
    private(set) var sources: [AudioSource] = []
    private(set) var lastError: String?

    func refresh() {
        do {
            sources = try Self.buildSources()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func buildSources() throws -> [AudioSource] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID
        }
        let appsByPID = Dictionary(apps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })

        // 앱 pid → 그 앱에 속한 오디오 프로세스들
        var grouped: [pid_t: (objectIDs: [AudioObjectID], playing: Bool)] = [:]

        for objectID in try AudioObjectID.readProcessList() {
            guard let pid = try? objectID.readProcessPID(), pid > 0, pid != ownPID else { continue }
            guard let owner = owningApp(pid: pid, bundleID: objectID.readProcessBundleID(), apps: apps, appsByPID: appsByPID)
            else { continue } // 사용자 앱에 속하지 않는 데몬은 목록에서 뺀다 (시스템 전체 옵션으로 커버)

            var entry = grouped[owner.processIdentifier] ?? ([], false)
            entry.objectIDs.append(objectID)
            entry.playing = entry.playing || objectID.readProcessIsRunningOutput()
            grouped[owner.processIdentifier] = entry
        }

        let appSources: [AudioSource] = grouped.compactMap { pid, entry in
            guard let app = appsByPID[pid] else { return nil }
            return AudioSource(
                id: "app-\(pid)",
                name: app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)",
                kind: .app(processObjectIDs: entry.objectIDs.sorted()),
                bundleURL: app.bundleURL,
                bundleID: app.bundleIdentifier,
                isPlaying: entry.playing
            )
        }
        .sorted { lhs, rhs in
            // 재생 중인 앱을 위로, 그다음 이름순
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let systemWide = AudioSource(id: "system", name: "시스템 전체 (CoNo 제외)", kind: .systemWide, bundleURL: nil, isPlaying: false)
        return [systemWide] + appSources
    }

    /// 오디오 프로세스가 어느 사용자 앱 소속인지 판정.
    /// 1) 책임 프로세스 pid 가 사용자 앱이면 그 앱 (XPC 헬퍼·WebKit GPU 프로세스 커버)
    /// 2) 번들 ID 가 앱 번들 ID 의 하위(`앱ID.`)이면 그 앱 (Chrome/Electron 헬퍼 폴백)
    private static func owningApp(
        pid: pid_t,
        bundleID: String?,
        apps: [NSRunningApplication],
        appsByPID: [pid_t: NSRunningApplication]
    ) -> NSRunningApplication? {
        if let app = appsByPID[pid] { return app }
        if let responsible = responsiblePID(for: pid), let app = appsByPID[responsible] { return app }
        guard let bundleID else { return nil }
        return apps.first { app in
            guard let appBundleID = app.bundleIdentifier else { return false }
            return bundleID.hasPrefix(appBundleID + ".")
        }
    }
}

// MARK: - Responsible PID (private SPI, 없으면 번들 ID 폴백만 사용)

private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t

/// libsystem 의 `responsibility_get_pid_responsible_for_pid`. 공개 API 가 아니라 dlsym 으로 찾고,
/// 못 찾으면 nil — 이 경우 번들 ID 접두어 매칭만으로 동작한다.
private let responsiblePIDFunction: ResponsiblePIDFunction? = {
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
    guard let symbol = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
}()

private func responsiblePID(for pid: pid_t) -> pid_t? {
    guard let responsiblePIDFunction else { return nil }
    let result = responsiblePIDFunction(pid)
    return result > 0 && result != pid ? result : nil
}
