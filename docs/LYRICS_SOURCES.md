# 추가 가사 소스와 로컬 KRC

TL;DR: **KRC 로컬 파일의 단어 싱크를 지원한다. QQ·Kugou·Musixmatch 온라인 검색은 연결하지 않았다.** 이번 확인에서 Kugou의 HTTPS 곡 검색 경로가 인증서 검증에 실패했고, QQ의 QRC 복호화와 Musixmatch의 공식 이용 권한은 별도 준비가 필요했다. 기존 LRCLIB·NetEase·AMLL·Apple Music 설정은 그대로다.

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

## 온라인 소스 확인 결과

확인일: 2026-10-03. 공개 원본 코드와 아래의 소규모 읽기 요청에 근거한다. 비공식 경로는 서비스가 제공하는 공식 API 계약으로 간주하지 않는다.

| 소스 | 단어 싱크 형식과 구현 근거 | 이번 확인 및 남은 조건 |
| --- | --- | --- |
| QQ Music | QRC. 커뮤니티 구현은 곡 ID·세션 준비 후 QRC 응답을 받아 전용 3DES 변형, zlib, XML `LyricContent` 순서로 처리한다. | 구현을 조사했으며 실제 QQ 요청이나 세션 발급은 하지 않았다. 검증된 Swift 복호화 구현, 합성 테스트 벡터, 정상 서비스 접근과 사용 조건 확인이 필요하다. |
| Kugou | KRC. 곡 검색에서 얻은 식별값으로 가사 후보를 검색하고, 후보 응답의 ID·접근 키로 KRC를 받는 경로가 공개 구현에 있다. | 가사 키워드 검색은 HTTP 200·서비스 성공 응답이었지만 후보가 0개였다. 다음 HTTPS 곡 검색 단계는 인증서 호스트명 불일치로 중단했다. 현재 환경에서 정상 인증서 검증을 통과하는 지원 경로가 먼저 확인되어야 한다. |
| Musixmatch | richsync JSON. 공식 Lyrics API는 플랜과 사용자 자신의 API 키가 필요하다. | 공식 권한이나 키가 없는 상태다. 선택한 플랜의 richsync 제공 여부, 표시·출처·캐시 조건을 확인하고 정식 API 계약으로 구현해야 한다. |

### QQ Music

[LyricsKit의 QQ 제공자](https://github.com/ddddxxx/LyricsKit/blob/master/Sources/LyricsService/Provider/QQMusic.swift)는 일반 base64 LRC를 가져온다. 이 소스만 추가해도 QRC 단어 싱크가 생기는 것은 아니다.

[lyrimuse의 QQ 구현](https://github.com/Yudaotor/lyrimuse/blob/main/lyrimuse-collector/qq.go)과 [QRC용 DES 구현](https://github.com/Yudaotor/lyrimuse/blob/main/lyrimuse-collector/des3_qmusic.go)은 표준 DES 라이브러리 호출과 같다고 가정할 수 없는 별도 알고리즘을 사용한다. 따라서 기존 CryptoKit/CommonCrypto나 LRC 파서만 연결하는 작은 변경으로 완료할 수 없다. 원본 참고 프로젝트에는 [QQMusicDecoder](https://github.com/WXRIW/QQMusicDecoder)와 [LDDC](https://github.com/chenmozhijin/LDDC)가 있다.

최소 후속 범위는 QRC 전용 디코더의 독립 구현·출처 표기·손상/크기 제한·합성 회귀 검증이다. 온라인 후보 결합은 정상 검색·취득 경로와 서비스 조건을 확인한 다음 연결한다.

### Kugou

[LyricsKit의 Kugou 제공자](https://github.com/ddddxxx/LyricsKit/blob/master/Sources/LyricsService/Provider/Kugou.swift)와 [lyrimuse의 구현](https://github.com/Yudaotor/lyrimuse/blob/main/lyrimuse-collector/kugou.go)에 후보 검색·KRC 취득 흐름이 있다. 공개 코드가 남아 있다는 사실만으로 해당 경로가 현재 환경에서 동작하거나 지원되는 API라고 판단할 수는 없다.

이번에는 `https://lyrics.kugou.com/search`에 제한된 키워드 검색을 했고, `%20` 공백 인코딩으로도 후보가 없었다. 이는 해당 곡의 가사 부재를 입증하지 않는다. 이어 `https://mobilecdn.kugou.com/api/v3/search/song`을 한 번 읽는 과정에서 **TLS 인증서 호스트명 불일치**가 발생해 중단했다. 인증서 검증 해제, HTTP 전환, 대체 호스트로 우회는 하지 않았으며 실제 가사 다운로드 단계까지 진행하지 않았다.

이 결과로 온라인 Kugou 토글은 추가하지 않는다. 로컬 KRC 디코더는 네트워크와 독립적으로 사용할 수 있다. 나중에 온라인 연결을 검토할 때는 정상 HTTPS 검색·후보·다운로드 한 흐름을 확인한 뒤, 응답 크기 상한, 제한된 요청 수, 취소, 오류 백오프, 캐시와 출처 표시를 기존 소스 구조에 맞춰 적용한다.

### Musixmatch

[Musixmatch의 공식 Postman 게시자](https://www.postman.com/musixmatch-dev)와 [공식 Lyrics API 컬렉션](https://www.postman.com/musixmatch-dev/musixmatch-apis/collection/pqm8o6w/lyrics-api)은 API 플랜과 API 키 사용을 안내한다. [richsync 공식 문서](https://docs.musixmatch.com/lyrics-api/track/track-richsync-get)와 [API 약관](https://about.musixmatch.com/apiterms)은 이번 도구에서 본문을 읽지 못했으므로, 현재 플랜 가격·요청 한도·richsync 권한·캐시 허용 범위는 확정하지 않았다.

일부 비공식 구현의 데스크톱 클라이언트 토큰 발급, 서비스 차단 뒤 호스트 변경 같은 방식은 사용하지 않는다. 공식 권한이 준비되면 richsync JSON 자체는 추가 라이브러리 없이 변환할 수 있다. 사용자별 비밀 키를 앱 번들·저장소·일반 로그에 포함하지 않는 설정과 명확한 미설정/실패 상태가 필요하다.

## 구현 상태의 구분

로컬 KRC 가져오기는 구현 범위에 포함한다. QQ QRC·Kugou 온라인·Musixmatch richsync 검색은 미구현 상태로 유지하며, GitHub 이슈 [#3](https://github.com/hsu3046/CoNoAI/issues/3)의 온라인 연동 완료 조건과 구분한다. 실제 연결을 검증하지 않은 소스 이름이나 선택 토글을 사용자에게 표시하지 않는다.
