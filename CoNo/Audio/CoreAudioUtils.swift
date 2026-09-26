// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// Core Audio 프로퍼티 읽기 헬퍼.
// insidegui/AudioCap (Copyright (c) 2024 Guilherme Rambo, BSD-2-Clause) 의
// CoreAudioUtils.swift 를 기반으로 수정했다. 원 라이선스 전문은 THIRD_PARTY_NOTICES.md 참조.

import AudioToolbox
import Foundation

/// Core Audio 호출 실패. `status` 는 OSStatus 원본을 보존한다 (진단용).
struct CoreAudioError: LocalizedError {
    let message: String
    let status: OSStatus?

    init(_ message: String, status: OSStatus? = nil) {
        self.message = message
        self.status = status
    }

    var errorDescription: String? {
        guard let status else { return message }
        return "\(message) (OSStatus \(status))"
    }
}

// MARK: - Constants

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = kAudioObjectUnknown

    var isValid: Bool { self != .unknown }
}

// MARK: - System object

extension AudioObjectID {
    /// `kAudioHardwarePropertyProcessObjectList` — HAL 에 연결된 오디오 클라이언트 프로세스 목록.
    static func readProcessList() throws -> [AudioObjectID] {
        try AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList)
    }

    /// `kAudioHardwarePropertyTranslatePIDToProcessObject`. 해당 pid 가 HAL 클라이언트가 아니면 throw.
    static func translatePIDToProcessObjectID(_ pid: pid_t) throws -> AudioObjectID {
        let objectID = try AudioObjectID.system.read(
            kAudioHardwarePropertyTranslatePIDToProcessObject,
            defaultValue: AudioObjectID.unknown,
            qualifier: pid
        )
        guard objectID.isValid else { throw CoreAudioError("pid \(pid) 에 해당하는 오디오 프로세스가 없습니다") }
        return objectID
    }

    static func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice, defaultValue: AudioDeviceID.unknown)
    }
}

// MARK: - Process object

extension AudioObjectID {
    func readProcessPID() throws -> pid_t {
        try read(kAudioProcessPropertyPID, defaultValue: pid_t(-1))
    }

    func readProcessBundleID() -> String? {
        guard let value = try? readString(kAudioProcessPropertyBundleID), !value.isEmpty else { return nil }
        return value
    }

    /// 지금 이 순간 출력(재생) 중인지.
    func readProcessIsRunningOutput() -> Bool {
        (try? readBool(kAudioProcessPropertyIsRunningOutput)) ?? false
    }
}

// MARK: - Device / tap object

extension AudioObjectID {
    func readDeviceUID() throws -> String {
        try readString(kAudioDevicePropertyDeviceUID)
    }

    func readNominalSampleRate() throws -> Double {
        try read(kAudioDevicePropertyNominalSampleRate, defaultValue: Float64(0))
    }

    /// `kAudioTapPropertyFormat` — 탭이 내보내는 스트림 포맷.
    func readTapStreamDescription() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }
}

// MARK: - Generic property access

extension AudioObjectID {
    func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        defaultValue: T
    ) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        return try read(&address, defaultValue: defaultValue, qualifierSize: 0, qualifier: nil)
    }

    func read<T, Q>(
        _ selector: AudioObjectPropertySelector,
        defaultValue: T,
        qualifier: Q
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var inQualifier = qualifier
        let qualifierSize = UInt32(MemoryLayout<Q>.size)
        return try withUnsafePointer(to: &inQualifier) { qualifierPtr in
            try read(&address, defaultValue: defaultValue, qualifierSize: qualifierSize, qualifier: qualifierPtr)
        }
    }

    func readArray(_ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard err == noErr else { throw CoreAudioError("프로퍼티 크기 읽기 실패 \(selector)", status: err) }

        var value = [AudioObjectID](repeating: .unknown, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &value)
        guard err == noErr else { throw CoreAudioError("프로퍼티 배열 읽기 실패 \(selector)", status: err) }
        return value
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        // CFString 은 +1 retained 로 돌아오므로 Unmanaged 로 받아 소유권을 넘겨받는다.
        let value: Unmanaged<CFString>? = try read(selector, defaultValue: nil)
        guard let value else { return "" }
        return value.takeRetainedValue() as String
    }

    func readBool(_ selector: AudioObjectPropertySelector) throws -> Bool {
        let value: UInt32 = try read(selector, defaultValue: 0)
        return value != 0
    }

    private func read<T>(
        _ address: inout AudioObjectPropertyAddress,
        defaultValue: T,
        qualifierSize: UInt32,
        qualifier: UnsafeRawPointer?
    ) throws -> T {
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, qualifierSize, qualifier, &dataSize)
        guard err == noErr else { throw CoreAudioError("프로퍼티 크기 읽기 실패 \(address.mSelector)", status: err) }

        var value = defaultValue
        err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(self, &address, qualifierSize, qualifier, &dataSize, ptr)
        }
        guard err == noErr else { throw CoreAudioError("프로퍼티 읽기 실패 \(address.mSelector)", status: err) }
        return value
    }
}
