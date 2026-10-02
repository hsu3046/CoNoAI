# 외부 가사 서비스 접근과 로컬 가사

TL;DR: **개인 가사는 Mac·웹 보관함에 비공개로 저장하고, 검토 후 선택한 가사만 LRCLIB에 공개한다.** 기존 온라인 조회는 HTTPS·응답 크기·인증 세대·오류별 대기 조건을 검사한다. QQ·Kugou·Musixmatch 온라인 검색은 아직 연결하지 않았다.

## 공통 접근 정책

`LyricsHTTPClient.shared`는 조회와 명시적 게시가 함께 쓰는 세션이다. 서비스별 고정 HTTPS 호스트, 표준 TLS 검증, 같은 호스트로의 HTTPS 리다이렉트만 허용한다. 다른 호스트로 인증 헤더를 넘기지 않는다. 쿠키 자동 저장과 URL 캐시는 사용하지 않으며 클라이언트 이름은 CoNo로 표시한다.

- 요청/전체 리소스 시간 제한은 10초/25초다. 일반 응답은 1 MiB, AMLL 색인·Apple 공개 웹 스크립트는 최대 8 MiB로 제한한다. 선언된 크기와 실제 스트림 크기를 모두 검사하고 취소 시 읽기를 중단한다.
- HTTP 401/403은 인증·이용 권한, 429는 요청 제한, 5xx는 일시 장애로 구분한다. `Retry-After` 초/HTTP 날짜를 존중하며, 없으면 각각 30초/15초 동안 같은 서비스에 재요청하지 않는다. 게시 POST는 자동 재시도하지 않는다.
- 잘못된 HTTP 200 본문, 인증 오류, TLS 오류, 취소는 “가사 없음”으로 캐시하지 않는다. NetEase·AMLL은 서로 독립된 캐시를 사용한다. AMLL 색인은 검증 후 교체하며 실패 시 이전 유효 파일을 보존한다.
- LRCLIB의 앞선 유효 후보는 후속 검색이 실패해도 사용할 수 있지만 불완전한 결과를 디스크에 캐시하지 않는다. 이전 오류 캐시와 분리하기 위해 `lyrics-v4`/`lyrics-extra-v4`를 사용한다.
- 설정 › 가사에서 실제 최근 요청/캐시/오류 상태를 확인하고 **현재 곡 다시 검색**할 수 있다. 직접 적용한 내 가사는 온라인 재조회가 덮지 않는다.

## 서비스별 조건

| 서비스 | 조건과 처리 |
| --- | --- |
| LRCLIB | 공개 조회에 API 키가 필요 없다. 정확 조회는 제목·가수가 있을 때만 시도하고, 길이는 1…3,600초일 때만 보낸다. 검색은 별도로 진행한다. 공개에는 제목·가수·실제 길이와 명시 확인이 필요하며 일반 가사만으로도 게시할 수 있다. |
| NetEase | 비공식 조회 경로다. 서비스 코드와 JSON 구조를 확인하며 접근 실패를 유효한 빈 결과와 구분한다. |
| AMLL | 공개 커뮤니티 TTML 자료다. 색인과 가사 본문을 검증하고 출처별 후보를 합친다. |
| Apple Music | 본인 계정과 이용 가능한 구독·지역이 필요하다. 기존 웹 호환 연결은 공식 MusicKit 가사 API가 아니며 모든 곡을 보장하지 않는다. 사용자 토큰은 Keychain, 가사는 메모리에서만 사용한다. |

Apple Music 사용자 토큰에 고정 6개월 만료일을 표시하지 않는다. 6개월 상한은 개발자 토큰 규칙이며, 사용자 토큰은 실제 인증 응답으로 재연결 필요 상태를 판단한다. Keychain 저장·삭제 실패 시 성공한 것처럼 처리하지 않고 이전 상태를 보존한다. 재연결·연결 해제마다 세대를 바꾸어 오래된 401/403, 지역 조회, 가사 결과가 새 연결을 덮지 못하게 한다. 로그인 쿠키는 정확한 Apple 도메인 경계와 HTTPS 조건을 검사한다.

계정 교체·해제 시 Controller의 이전 Apple 후보와 진행 중 조회도 무효화한다. 구독 가사는 자동 단어 학습 파일에 쓰거나 그 파일에서 읽지 않는다. 앱 시작 시 구형 혼합 캐시 `lyrics-extra-v1/v2/v3`와 출처·스키마·파일 키가 검증된 Apple 학습 JSON을 정리한다. 새 v4 캐시·개인 보관함·직접 적용한 가사·다른 출처의 학습은 유지한다. 손상 파일·심볼릭 링크·삭제 실패는 보존하고 확인이 필요한 건수를 안내한다.

근거: [LRCLIB 정확 조회](https://github.com/tranxuanthang/lrclib/blob/05ad8590f6fc4d47a2d74e70f4915273df20f63c/server/src/routes/get_lyrics_by_metadata.rs), [게시 서버](https://github.com/tranxuanthang/lrclib/blob/05ad8590f6fc4d47a2d74e70f4915273df20f63c/server/src/routes/publish_lyrics.rs), [Apple 사용자 인증](https://developer.apple.com/documentation/applemusicapi/user-authentication-for-musickit), [Apple 개발자 토큰](https://developer.apple.com/documentation/applemusicapi/generating-developer-tokens), [WWDC 사용자 토큰 수명 설명](https://developer.apple.com/videos/play/wwdc2022/10148/). 실제 구독 계정으로의 서비스별 성공 여부와 합성 응답 테스트는 구분한다.

## 로컬 KRC 구현

`CoNo/Lyrics/Core/KRCLyrics.swift`는 사용자가 가져온 `.krc` 바이트를 기존 `LRCParser`가 읽는 enhanced LRC로 바꾼다.

```swift
let lrc = try KRCLyrics.enhancedLRC(from: data)
let lyrics = LRCParser.parse(lrc)
```

- KRC의 `krc1` 헤더, 형식에 정의된 고정 XOR 마스크, zlib 압축, UTF-8을 순서대로 처리한다. 고정 마스크는 서비스 로그인이나 API 인증 키가 아니다.
- `[줄 시작 ms,줄 길이 ms]<줄 안 단어 시작 ms,단어 길이 ms,표시값>본문`의 상대 시각을 절대 시각으로 바꾼다. 단어 사이 휴식과 마지막 단어 종료, 줄 전체 종료를 보존한다.
- 한글·결합 문자·이모지는 기존 파서의 `Character` 기준 글자 범위로 연결된다. `[offset:ms]`는 기존 LRC 관례를 따르며 양수이면 표시를 앞당긴다.
- 제목·아티스트와 `language` 번역/발음 메타데이터는 표시 본문에 합치지 않는다. 번역·발음 병기는 이번 범위에 포함하지 않는다.
- 원본은 최대 **1 MiB**, 압축 해제 결과는 최대 **2 MiB**다. 시각은 24시간 이내, 가사 줄 10,000개·단어 50,000개·한 줄 64 KiB를 상한으로 둔다.
- 잘못된 헤더, 압축 손상·체크섬 오류·압축 스트림 뒤의 추가 데이터, 잘못된 UTF-8, 음수/넘침/겹치는 단어 시각을 거부한다. 본문이 LRC 시각 태그로 재해석되어 글자가 사라질 수 있는 경우도 오류로 알린다.
- macOS에 포함된 zlib를 사용한다. 새 Swift 패키지, 별도 모델, 네트워크 요청은 없다.

`CoNoTests/KRCLyricsTests.swift`는 테스트 중 압축한 합성 문장만 사용한다. 실제 서비스 가사·응답·접근 키를 fixture로 보관하지 않는다. 로컬 저장소는 기존 JSON 형식을 유지하며 KRC 원본 바이트는 base64 문자열로 저장한다.

형식 근거는 [LyricsKit의 KRC 디코더](https://github.com/ddddxxx/LyricsKit/blob/master/Sources/LyricsService/Parser/KugouKrcDecrypter.swift), [KRC 파서](https://github.com/ddddxxx/LyricsKit/blob/master/Sources/LyricsService/Parser/KugouKrcParser.swift), [lyrimuse의 Kugou 구현](https://github.com/Yudaotor/lyrimuse/blob/main/lyrimuse-collector/kugou.go)이다. 패키지나 소스 파일을 복사하지 않고 형식을 참고해 구현했다. 출처는 `THIRD_PARTY_NOTICES.md`에도 기록한다.

## 로컬 QRC 구현

`CoNo/Lyrics/Core/QRCLyrics.swift`도 같은 enhanced LRC 반환 계약을 사용한다.

```swift
let lrc = try QRCLyrics.enhancedLRC(from: data)
let lyrics = LRCParser.parse(lrc)
```

- QQ의 로컬 QRC 바이너리, 파일로 내보낸 16진수 암호문, 이미 복호화된 QRC XML·본문을 구분해 처리한다. 로컬 바이너리는 고정 XOR 포장을 먼저 해제한다.
- QRC 전용 DES 변형은 [QQMusicDecoder의 MIT 원본](https://github.com/WXRIW/QQMusicDecoder/tree/0e1494194523dd885405812a91ee9b9702bfb30c)을 Swift로 이식했다. 표준 DES와 다른 S-box 항목·키 배치·바이트 순서를 유지한다. 로컬 XOR는 [qmc-decode의 MIT 원본](https://github.com/jixunmoe/qmc-decode/tree/0266189adfa135b7471fb3452f7e777f0ff210e9)을 이식했다. 두 저작권자와 MIT 전문은 `THIRD_PARTY_NOTICES.md`에 보존한다.
- `[줄 시작 ms,줄 길이 ms]본문(단어 시작 ms,단어 길이 ms)`에서 **단어 시작은 절대 곡 시각**이다. KRC의 줄 내부 상대 시각과 다르게 해석한다. 단어가 없는 줄 전용 가사도 줄 종료를 보존한다.
- XML의 `LyricContent` 속성에 직접 들어 있는 줄바꿈·탭이 공백으로 바뀌지 않게 처리한다. `DOCTYPE`·사용자 정의 엔티티·외부 엔티티 접근·중복 본문·32단계를 넘는 XML 중첩은 거부한다.
- 원본 1 MiB·압축 해제 2 MiB, 시각 24시간, 줄 10,000개·단어 50,000개·한 줄 64 KiB 상한을 적용한다. 손상, 범위 밖/겹치는 시각, LRC 변환에서 사라질 수 있는 문자도 검사한다. 암호문의 마지막 8바이트 블록에서 생기는 최대 7바이트 패딩만 허용하고 추가 블록은 거부한다.
- `.qrc` 원본 바이트는 `.krc`와 같은 JSON base64 저장 경로를 쓴다. 새 패키지나 서비스 토큰은 없고, 압축 해제는 macOS system zlib를 사용한다.

복호화 검증은 자체 구현으로 암호화한 뒤 다시 푸는 순환 테스트에 의존하지 않는다. [LDDC의 원본 Python 함수](https://github.com/chenmozhijin/LDDC/blob/84631e8cd011fcc3f71ca0ae017e2c9758958ffc/LDDC/core/decryptor/tripledes.py)를 별도 임시 환경에서 실행해 만든 **105개 합성 블록**과 합성 XML 암호문을 고정 벡터로 사용했다. 그 코드의 의존 캐시 decorator만 제거했고 암호 함수는 바꾸지 않았다. 로컬 XOR의 32,767바이트 경계, 압축 크기 상한, Unicode·XML 줄바꿈·오류 처리도 `CoNoTests/QRCLyricsTests.swift`에서 확인한다. 원본 가사·실제 서비스 응답·계정 토큰은 포함하지 않는다.

## 온라인 소스 확인 결과

확인일: 2026-10-03. 공개 원본 코드와 아래의 소규모 읽기 요청에 근거한다. 비공식 경로는 서비스가 제공하는 공식 API 계약으로 간주하지 않는다.

| 소스 | 단어 싱크 형식과 구현 근거 | 이번 확인 및 남은 조건 |
| --- | --- | --- |
| QQ Music | QRC 전용 DES 변형, zlib, XML `LyricContent`를 처리하는 로컬 디코더를 구현·검증했다. | 공개 곡 검색 GET 1회가 HTTP 500이어서 온라인 검증을 중단했다. 정상 검색·취득 경로와 사용 조건 확인이 남았다. 세션·토큰 발급은 시도하지 않았다. |
| Kugou | KRC. 곡 검색에서 얻은 식별값으로 가사 후보를 검색하고, 후보 응답의 ID·접근 키로 KRC를 받는 경로가 공개 구현에 있다. | 가사 키워드 검색은 HTTP 200·서비스 성공 응답이었지만 후보가 0개였다. 다음 HTTPS 곡 검색 단계는 인증서 호스트명 불일치로 중단했다. 현재 환경에서 정상 인증서 검증을 통과하는 지원 경로가 먼저 확인되어야 한다. |
| Musixmatch | richsync JSON. 공식 Lyrics API는 플랜과 사용자 자신의 API 키가 필요하다. | 공식 권한이나 키가 없는 상태다. 선택한 플랜의 richsync 제공 여부, 표시·출처·캐시 조건을 확인하고 정식 API 계약으로 구현해야 한다. |

### QQ Music

[LyricsKit의 QQ 제공자](https://github.com/ddddxxx/LyricsKit/blob/master/Sources/LyricsService/Provider/QQMusic.swift)는 일반 base64 LRC를 가져온다. 이 소스만 추가해도 QRC 단어 싱크가 생기는 것은 아니다.

[lyrimuse의 QQ 구현](https://github.com/Yudaotor/lyrimuse/blob/main/lyrimuse-collector/qq.go)과 [QRC용 DES 구현](https://github.com/Yudaotor/lyrimuse/blob/main/lyrimuse-collector/des3_qmusic.go)은 표준 DES 라이브러리 호출과 같다고 가정할 수 없는 별도 알고리즘을 사용한다. 이번 로컬 지원에서는 위의 MIT 원본 이식과 독립 벡터 검증으로 이 부분을 완료했다.

온라인은 LyricsKit의 공개 검색 경로 `https://c.y.qq.com/soso/fcgi-bin/client_search_cp`에 `format=json`, `outCharset=utf-8`, `p=1`, `n=1`, `w=IU`로 무인증 GET을 한 번 보냈으나 **HTTP 500**이었다. 응답 본문·가사·토큰은 출력하거나 저장하지 않았다. 여기서 중단했고 대체 호스트·세션 발급·클라이언트 위장·인증서 우회는 시도하지 않았다. 이 환경에서 정상 검색·취득 경로와 서비스 조건을 확인하기 전에는 온라인 후보 결합이나 QQ 소스 토글을 추가하지 않는다.

### Kugou

[LyricsKit의 Kugou 제공자](https://github.com/ddddxxx/LyricsKit/blob/master/Sources/LyricsService/Provider/Kugou.swift)와 [lyrimuse의 구현](https://github.com/Yudaotor/lyrimuse/blob/main/lyrimuse-collector/kugou.go)에 후보 검색·KRC 취득 흐름이 있다. 공개 코드가 남아 있다는 사실만으로 해당 경로가 현재 환경에서 동작하거나 지원되는 API라고 판단할 수는 없다.

이번에는 `https://lyrics.kugou.com/search`에 제한된 키워드 검색을 했고, `%20` 공백 인코딩으로도 후보가 없었다. 이는 해당 곡의 가사 부재를 입증하지 않는다. 이어 `https://mobilecdn.kugou.com/api/v3/search/song`을 한 번 읽는 과정에서 **TLS 인증서 호스트명 불일치**가 발생해 중단했다. 인증서 검증 해제, HTTP 전환, 대체 호스트로 우회는 하지 않았으며 실제 가사 다운로드 단계까지 진행하지 않았다.

이 결과로 온라인 Kugou 토글은 추가하지 않는다. 로컬 KRC 디코더는 네트워크와 독립적으로 사용할 수 있다. 나중에 온라인 연결을 검토할 때는 정상 HTTPS 검색·후보·다운로드 한 흐름을 확인한 뒤, 응답 크기 상한, 제한된 요청 수, 취소, 오류 백오프, 캐시와 출처 표시를 기존 소스 구조에 맞춰 적용한다.

### Musixmatch

[Musixmatch의 공식 Postman 게시자](https://www.postman.com/musixmatch-dev)와 [공식 Lyrics API 컬렉션](https://www.postman.com/musixmatch-dev/musixmatch-apis/collection/pqm8o6w/lyrics-api)은 API 플랜과 API 키 사용을 안내한다. [richsync 공식 문서](https://docs.musixmatch.com/lyrics-api/track/track-richsync-get)와 [API 약관](https://about.musixmatch.com/apiterms)은 이번 도구에서 본문을 읽지 못했으므로, 현재 플랜 가격·요청 한도·richsync 권한·캐시 허용 범위는 확정하지 않았다.

일부 비공식 구현의 데스크톱 클라이언트 토큰 발급, 서비스 차단 뒤 호스트 변경 같은 방식은 사용하지 않는다. 공식 권한이 준비되면 richsync JSON 자체는 추가 라이브러리 없이 변환할 수 있다. 사용자별 비밀 키를 앱 번들·저장소·일반 로그에 포함하지 않는 설정과 명확한 미설정/실패 상태가 필요하다.

## 구현 상태의 구분

로컬 KRC·QRC 가져오기는 구현 범위에 포함한다. QQ·Kugou 온라인·Musixmatch richsync 검색은 미구현 상태로 유지하며, GitHub 이슈 [#3](https://github.com/hsu3046/CoNoAI/issues/3)의 온라인 연동 완료 조건과 구분한다. 실제 연결을 검증하지 않은 온라인 소스 이름이나 선택 토글을 사용자에게 표시하지 않는다.
