// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

/// 사용자 설정을 바꾸지 않고 채점에 영향을 주는 상태를 함께 안내한다.
enum SingingNotice {
    static func message(failure: String? = nil, isListening: Bool, isBluetooth: Bool, guideVocalLevel: Double) -> String? {
        if let failure { return failure }
        guard isListening else { return nil }
        var messages: [String] = []
        if isBluetooth {
            messages.append("블루투스 마이크 사용 중이에요. 이어폰 음질이 낮아지면 Mac 내장 마이크로 바꿔 주세요.")
        }
        if guideVocalLevel > 0 {
            messages.append("가이드 보컬이 켜져 있어요. 스피커의 원곡 목소리가 내 노래로 채점될 수 있으니 정확한 채점에는 꺼 주세요.")
        }
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }
}
