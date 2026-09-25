// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later

import Foundation

extension URLComponents {
    /// URLComponents 는 쿼리 값의 `+` 를 그대로 둔다. 서버는 `+` 를 공백으로 읽으므로
    /// "Love + Hate" 가 "Love   Hate" 로 조회된다 → `+` 를 %2B 로 바꾼 URL.
    var urlEncodingPlus: URL {
        var encoded = self
        encoded.percentEncodedQuery = percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return encoded.url!
    }
}
