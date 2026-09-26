// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 키보드의 재생/일시정지(⏯) 미디어 키를 대신 눌러, 음악 앱 말고도(브라우저의 YouTube Music·Melon 등) 멈추고 이어 틀게 한다.
// - 합성 키 이벤트를 보내려면 "손쉬운 사용" 권한이 필요하다 (처음 한 번 시스템이 묻는다).
// - 미디어 키는 토글이고, macOS 가 "지금 재생 중" 으로 보는 앱에 간다 → 보내기 전에 캡처 소리로 재생 여부를 확인하고,
//   보낸 뒤 소리가 안 멈추면 되돌리는 건 KaraokeEngine 이 한다.

import AppKit
import ApplicationServices

enum MediaKey {
    /// IOKit ev_keymap.h 의 NX_KEYTYPE_PLAY
    private static let playKey = 16

    /// 권한이 있으면 ⏯ 를 한 번 누른다. 없으면 권한 창을 띄우고 false.
    @MainActor
    static func pressPlayPause() -> Bool {
        guard AXIsProcessTrusted() else {
            // kAXTrustedCheckOptionPrompt 의 값 (전역 변수는 Swift 6 동시성 검사에 걸려 문자열로 쓴다)
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return false
        }
        post(keyDown: true)
        post(keyDown: false)
        return true
    }

    private static func post(keyDown: Bool) {
        // 시스템 정의 이벤트 subtype 8 = 보조 키. data1 = 키 코드 << 16 | (누름 0xA / 뗌 0xB) << 8
        let state = keyDown ? 0xA : 0xB
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: (playKey << 16) | (state << 8),
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}
