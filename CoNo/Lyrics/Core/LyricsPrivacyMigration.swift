// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation

/// 이전 버전이 만든 Apple 구독 가사 사본만 정리한다. 개인 가사 저장소는 전달하지 않는다.
/// 앱 시작 시 utility 작업에서 한 번 호출한다. 완료 플래그는 남기지 않아 실패/구버전 재실행 뒤 재시도할 수 있다.
enum LyricsPrivacyMigration {
    struct Report: Equatable, Sendable {
        var removedCacheDirectories = 0
        var removedLearnedFiles = 0
        var unreadablePaths = 0
        var failedRemovals = 0
        var preservedSymbolicLinks = 0

        var needsAttention: Bool { unreadablePaths > 0 || failedRemovals > 0 || preservedSymbolicLinks > 0 }
    }

    private struct LearnedDocument: Decodable {
        let schemaVersion: Int
        let identity: WordTimingIdentity
        let lines: [LearnedWordTiming]
    }
    private static let maximumLearnedBytes = 2_097_152

    /// - Parameters:
    ///   - cachesRoot: 앱 전용 Caches/space.knowai.cono 폴더. 세 개의 정확한 구형 하위 폴더만 대상이다.
    ///   - learnedDirectory: Application Support/space.knowai.cono/learned-word-timings 폴더.
    /// 경로·본문은 반환하거나 로그에 남기지 않고 정리/오류 수만 반환한다.
    static func run(cachesRoot: URL, learnedDirectory: URL) -> Report {
        var report = Report()
        let manager = FileManager.default
        if isDirectory(cachesRoot, manager: manager, report: &report) {
            for name in ["lyrics-extra-v1", "lyrics-extra-v2", "lyrics-extra-v3"] {
                let directory = cachesRoot.appendingPathComponent(name, isDirectory: true)
                guard isDirectory(directory, manager: manager, report: &report),
                      removableTree(directory, manager: manager, report: &report) else { continue }
                do {
                    try manager.removeItem(at: directory)
                    report.removedCacheDirectories += 1
                } catch { report.failedRemovals += 1 }
            }
        }
        cleanLearnedFiles(in: learnedDirectory, manager: manager, report: &report)
        return report
    }

    /// 임의 링크가 있는 캐시 트리는 통째로 보존한다. 링크 대상이나 다른 사용자 파일로 내려가지 않는다.
    private static func removableTree(_ directory: URL, manager: FileManager, report: inout Report) -> Bool {
        var failures = 0
        var links = 0
        guard let entries = manager.enumerator(at: directory, includingPropertiesForKeys: nil,
                                               errorHandler: { _, _ in failures += 1; return true }) else {
            report.unreadablePaths += 1
            return false
        }
        for case let file as URL in entries {
            do {
                let values = try manager.attributesOfItem(atPath: file.path)
                let type = values[.type] as? FileAttributeType
                if type == .typeSymbolicLink { links += 1; entries.skipDescendants() }
                else if type != .typeDirectory && type != .typeRegular { failures += 1 }
            } catch { failures += 1 }
        }
        report.unreadablePaths += failures
        report.preservedSymbolicLinks += links
        return failures == 0 && links == 0
    }

    private static func cleanLearnedFiles(in directory: URL, manager: FileManager, report: inout Report) {
        guard isDirectory(directory, manager: manager, report: &report) else { return }
        let files: [URL]
        do { files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch { report.unreadablePaths += 1; return }
        for file in files {
            let stem = file.deletingPathExtension().lastPathComponent
            // 앱이 쓰는 SHA-256 파일만 검사한다. 개인 파일·하위 폴더는 건드리지 않는다.
            guard file.pathExtension == "json", stem.utf8.count == 64,
                  stem.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
            do {
                let attributes = try manager.attributesOfItem(atPath: file.path)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    report.preservedSymbolicLinks += 1
                    continue
                }
                guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
                guard let size = attributes[.size] as? NSNumber, size.intValue <= maximumLearnedBytes else {
                    report.unreadablePaths += 1; continue
                }
                // 크기 조회 뒤 파일이 커져도 메모리에 무제한으로 읽지 않는다.
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: maximumLearnedBytes + 1) ?? Data()
                guard data.count <= maximumLearnedBytes else { report.unreadablePaths += 1; continue }
                let document = try JSONDecoder().decode(LearnedDocument.self, from: data)
                guard document.schemaVersion == 1 else { report.unreadablePaths += 1; continue }
                guard document.identity.candidateKey.hasPrefix("appleMusic:") else { continue }
                guard document.identity.storageKey == stem, document.lines.count <= 4_000,
                      Set(document.lines.map(\.lineIndex)).count == document.lines.count else {
                    report.unreadablePaths += 1; continue
                }
                for line in document.lines { try line.validate() }
                // decode/구조 검증이 실패한 학습 파일은 보존한다. 원문을 백업으로 복제하지 않는다.
                do {
                    try manager.removeItem(at: file)
                    report.removedLearnedFiles += 1
                } catch { report.failedRemovals += 1 }
            } catch { report.unreadablePaths += 1 }
        }
    }

    private static func isDirectory(_ url: URL, manager: FileManager, report: inout Report) -> Bool {
        guard url.isFileURL else { report.unreadablePaths += 1; return false }
        do {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                report.preservedSymbolicLinks += 1
                return false
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                report.unreadablePaths += 1
                return false
            }
            return true
        } catch {
            let error = error as NSError
            if error.domain != NSCocoaErrorDomain || ![NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                report.unreadablePaths += 1
            }
            return false
        }
    }
}
