# PriType 멀티에이전트 교차검증 리뷰 — 2026-07-21

## 개요

8개 차원(조합 정확성, 한/영 전환, 동시성, UX, 코드 품질, 견고성/보안, 테스트 커버리지, Open 이슈 근본원인)으로 병렬 리뷰 에이전트를 투입하고, 도출된 발견 35건 각각을 서로 다른 관점의 회의적 검증 에이전트 2명(반박 시도 / 사용자 영향)이 재검증했으며, 최종적으로 본 세션이 모든 핵심 발견을 현재 코드에서 직접 재확인했다. 총 78개 에이전트, 결과: **확정 26건(중복 병합 후 15건), 분쟁 2건, 반박 7건**.

- 기준 커밋: `eb459db` (`main`)
- 억지 이슈를 배제하기 위해 "구체적 실패 시나리오가 현재 코드에서 성립하는 항목만 보고"를 검증 기준으로 강제했고, 반박된 7건은 부록에 사유와 함께 남긴다.

## 기존 리뷰·수정 커밋과의 관계

이 리뷰는 [ProjectReview-2026-07-21.md](ProjectReview-2026-07-21.md)(R-01~R-20)와 **독립적으로** 수행됐다. 리뷰 진행 중 다음 커밋이 추가되었고, 본 리뷰의 검증 단계는 이 수정들을 반영한 HEAD 기준으로 재판정했다.

- `6d7b4a4` (R-01/R-02 대응): CI runner 격리, `SecureInputPolicy` 분리 및 stale Secure Input 복구
- `eb459db` (R-03/R-04 대응): 직접 삽입 어댑터 상태 모델(State enum) 재설계, `KeyMonitorLifecycle`(EventTapFailureTracker)로 CGEventTap→IOKit handoff exactly-once 보장

**교차검증이 위 수정의 유효성을 역으로 입증했다**: 1차 리뷰에서 나온 "handoff 후 이중 토글"(3건), "직접 삽입 fallback 텍스트 중복/유실"(2건) 주장은 검증 단계에서 전부 "현재 코드에 해당 경로 없음"으로 반박되었다(부록 참조). 즉 R-03/R-04 수정은 독립 검증 관점에서도 유효하다.

아래 신규 발견은 R-01~R-20에 **없거나**, 있더라도 새로운 메커니즘·심각도 근거가 추가된 항목만 담는다. 기존 항목과 겹치는 부분은 R-번호로 상호 참조한다.

## 우선순위 요약

| ID | 우선순위 | 영역 | 요약 | 검증 |
| --- | --- | --- | --- | --- |
| N-01 | P1 | 텍스트 무결성 | 조합 중 백스페이스가 확정 글자를 버퍼에서 pop → 한자 변환이 엉뚱한 글자를 대체 | 2/2 확정 + 직접 재현 추적 |
| N-02 | P1 | 전환키/전역 | Key Recorder가 일반 문자키를 바인딩으로 수용 → 그 키가 시스템 전역에서 삼켜짐 | 2/2 확정 + 직접 추적 |
| N-03 | P1 | 전환키/전역 | `toggleModifierIsDown` 고착 시 모든 keyDown에서 Command가 전역 스트리핑 | 2/2 확정 |
| N-04 | P2 | 설정 UX | Key Recorder가 현재 바인딩 키를 녹음 불가 — 탭이 먼저 소비해 모드가 토글됨 | 2/2 확정 + 직접 확인 |
| N-05 | P2 | Open #10 | 영어 편의 폴백의 캐럿-0 무조건 대문자화 + 문서 3곳·테스트가 버그를 정답으로 고정 | 2/2 확정 ×4차원 + 직접 확인 (R-06 보강) |
| N-06 | P2 | 설정 반영 | 시스템 텍스트 편의 설정을 프로세스 시작 시 1회만 스냅숏 — 재로그인 전까지 변경 무시 | 2/2 확정 ×3차원 |
| N-07 | P2 | 조합/호스트 | 한글 모드에서 Space를 무조건 소비 — Finder Quick Look 등 raw-space 동작 파괴 | 2/2 확정 |
| N-08 | P2 | 개발자 보안 | DEBUG 빌드가 Secure Input 게이트 **이전에** 원문 키 입력을 평문 로그로 기록 | 2/2 확정 + 직접 확인 |
| N-09 | P2 | 반응성 | 사전 로딩 중 한자키를 누르면 메인 스레드가 `loadLock`에 ~1초 블록 | 2/2 확정(심각도 하향) |
| N-10 | P2 | 테스트 | `englishModeAutoCapitalizationFallback` 테스트가 Open #10 증상을 정답으로 고정 외 갭 3건 | 2/2 확정 |
| N-11 | P3 | Secure Input | activateServer의 lightweight 컨텍스트가 필드 속성 휴리스틱을 일반 경로에서 미실행 | 2/2 확정(심각도 하향, R-02 후속) |
| N-12 | P3 | 조합 | KeyEventDedup 50ms 창이 문자·수정자 무시 — 이론상 초고속 동일키 입력 삼킴 | 2/2 확정 |
| N-13 | P3 | 실험 기능 | Blink 렌더러 분류 목록과 직접 삽입 거부 휴리스틱의 드리프트(Whale/Vivaldi/Opera/Spotify) | 2/2 확정 |
| N-14 | P3 | 시작 경로 | `cleanupStaleInputSources`의 HIToolbox plist snapshot read-modify-write 경쟁 | 2/2 확정 |
| N-15 | P3 | 권한 UX | 접근성 권한 회수→재부여 시 죽은 탭이 복구되지 않을 수 있음(초록 "허용됨" 표시 유지) | 분쟁 1:1, OS 동작 의존 |

Open 이슈: #10은 N-05(=R-06)로 코드 경로 확정, #9는 R-07(불완전 plist 편집 + 무검증 성공)이 유력하며 경쟁 가설이었던 "ASCII-capable 미선언" 메커니즘은 **라이브 TIS 프로브로 반박**됐다(아래 대응표).

---

## P1 — 즉시 수정 권장

### N-01. 조합 중 백스페이스가 확정 글자를 localTextBuffer에서 pop — 한자 변환이 엉뚱한 글자를 제안·파괴

**근거** — [`HangulComposer.swift:265-279`](../Sources/PriTypeCore/HangulComposer.swift#L265)

```swift
if keyCode == KeyCode.backspace {
    if !localTextBuffer.isEmpty {
        localTextBuffer.removeLast()      // ← 무조건 실행
    }
    if !context.isEmpty() {               // ← preedit 자모 분해로 이벤트 소비
        ...
```

`localTextBuffer`는 **확정(committed) 텍스트만** 담는다(`appendToBuffer` 호출처: space·ASCII 폴백·`updateComposition` commit·`commitComposition` 4곳뿐, preedit은 절대 안 들어감). 그런데 백스페이스가 조합 중인 preedit 자모를 분해하는 경우(`!context.isEmpty()`)에도 pop이 먼저 무조건 실행되어, 버퍼와 문서가 영구적으로 어긋난다.

**시나리오** — 어떤 앱에서든: ① `대한` 입력(확정, 문서=`대한`, 버퍼=`대한`) ② `ㅁ` 입력(preedit 시작) ③ 백스페이스로 `ㅁ` 제거 — 버퍼에서 `한`이 pop됨(버퍼=`대`, 문서는 여전히 `대한`) ④ 한자키 — preedit이 비어 있으므로 Strategy 2가 `버퍼.last`=`대`의 후보(大/代/對…)를 표시 ⑤ 선택 시 `replaceRange = (caret-1, 1)` — 문서의 `한`이 大로 대체되어 `대大`가 됨. **조회한 글자와 파괴한 글자가 모두 틀리다.** 같은 desync가 더블스페이스 마침표의 문맥 검사도 오염시킨다.

**조치** — pop을 `context.isEmpty()`(pass-through로 실제 확정 텍스트가 지워지는) 분기 안으로 이동. 확정 2음절 + 조합 시작 + 백스페이스 + 한자키 시퀀스의 회귀 테스트 추가.

### N-02. Key Recorder가 일반 문자키를 바인딩으로 수용 — 그 키가 시스템 전역에서 사라짐

**근거** — [`SettingsWindowController.swift:1083-1101`](../Sources/PriTypeCore/SettingsWindowController.swift#L1083), [`RightCommandSuppressor.swift:268-283`](../Sources/PriTypeCore/RightCommandSuppressor.swift#L268)

recorder의 keyDown 분기는 Escape(53) 외 **어떤 키든** 바인딩으로 저장한다. 수정자 없는 `a`를 녹음하면 `KeyBinding(keyCode: 0, modifiers: 0)` → `isModifierOnly == true`(modifiers==0의 의미), `isModifierKey == false`. 이후 CGEventTap의 keyDown 처리에서 `keyCode == toggleBinding.keyCode && !isModifierKey && isModifierOnly` → `triggerToggle()` + `return nil`.

**영향** — `a` 키가 **모든 앱에서** 입력되지 않고 누를 때마다 한/영이 토글된다. 사용자는 원인(설정의 전환키)을 연상하기 어렵고, 타이핑이 사실상 불가능해진다. Space/Return/Delete 같은 키를 녹음해도 동일하다. 시스템 단축키와 겹치는 조합(⌘Q 등)도 무경고 수용된다.

**조치** — recorder에서 프린터블 단독키·핵심 편집키를 거부(또는 명시적 2단계 확인). 최소한 바인딩 후보의 위험군(문자·숫자·Space·Return·Delete, modifiers==0)에 경고 UI. 잘못 저장된 기존 바인딩의 복구 경로(기본값 복원 버튼은 이미 존재)를 안내.

### N-03. `toggleModifierIsDown` 고착 시 모든 keyDown에서 Command가 전역 스트리핑

**근거** — [`RightCommandSuppressor.swift:296-305`](../Sources/PriTypeCore/RightCommandSuppressor.swift#L296)

토글 수정자(기본: 우측 Command)가 눌린 상태로 추적되는 동안, 다른 모든 keyDown에서 `modifierMask(for:)`가 **좌우 구분 없는** `.maskCommand`를 제거한다(의도된 "누른 채 타이핑" 기능). 문제는 release 이벤트가 유실되면 이 상태가 고착된다는 것: ① 탭이 `tapDisabledByTimeout`으로 잠시 비활성화된 사이 release가 지나감 ② R-18(좌·우 동일 수정자 동시 사용)의 aggregate flag 혼동. 고착되면 ⌘C/⌘V/⌘Tab이 전부 평문 키로 변해 **모든 앱의 Command 단축키가 죽는다**. 다음 토글키 누름-뗌에서야 자가 복구되며, 그 누름은 토글도 하지 않아 사용자에게는 "단축키도 전환키도 고장"으로 보인다.

**조치** — R-18의 권장대로 binding 키의 물리 down/up을 keyCode 중심으로 추적하고, 탭 재활성화 시(`.reenable` 분기) `toggleModifierIsDown`을 현재 `CGEventSource` 실측 플래그로 재동기화. 스트리핑 시 좌우 특정 마스크(`maskRightCommand` 등 device-specific flag) 사용 검토.

---

## P2 — 다음 릴리즈 전 처리

### N-04. Key Recorder가 현재 바인딩된 키를 녹음할 수 없다

**근거** — recorder는 [`NSEvent.addLocalMonitorForEvents`](../Sources/PriTypeCore/SettingsWindowController.swift#L1054)만 사용하고, `RightCommandSuppressor`에 이미 존재하는 `isRecordingKey`/`onKeyRecorded` 경로(탭 우선 캡처용, [RightCommandSuppressor.swift:178-201](../Sources/PriTypeCore/RightCommandSuppressor.swift#L178))를 **배선하지 않는다**. 세션 레벨 CGEventTap(`.headInsertEventTap`)이 local monitor보다 먼저 이벤트를 받으므로, 녹음 중 현재 전환키(우측 Command)를 누르면 녹음되는 대신 탭이 소비하고 **한/영이 토글**된다. 한자키도 동일. 즉 "우측 Command → 우측 Option으로 변경 후 다시 우측 Command로 복귀" 같은 흐름이 UI로는 불가능하고, 사용자에게는 recorder가 무반응으로 보인다.

**조치** — 녹음 시작 시 `RightCommandSuppressor.shared.isRecordingKey = true`를 설정하고 `onKeyRecorded` 콜백으로 바인딩을 받는다(죽은 인프라 재활용). 종료·창 닫힘 시 해제 보장.

### N-05. Open #10 확정 근본원인: 영어 편의 폴백의 캐럿-0 무조건 대문자화 (R-06 보강)

R-06이 이미 다룬 항목이지만, 4개 리뷰 차원이 독립적으로 동일 결론에 도달했고 다음 메커니즘·근거가 추가됐다.

- **"특정 입력창"의 정체**: [`BaseClientAdapter.textBeforeCursor`](../Sources/PriTypeCore/TextDelivery.swift#L148)는 `selectedRange().location == 0`이면 `""`를 반환하고, [`shouldAutoCapitalize`](../Sources/PriTypeCore/TextConvenienceHandler.swift#L220)는 빈 문자열에 무조건 true다. 따라서 **유효한 selectedRange를 보고하는 호스트의 캐럿 위치 0**(빈 필드 전부 + location 0을 잘못 보고하는 Chromium/Electron 필드)에서만 발화한다 — 이슈 영상의 "특정 입력창" 조건과 일치. macOS 네이티브는 뷰 단위 opt-in(`isAutomaticCapitalizationEnabled`)이라 URL바·검색창·코드 편집기에서는 절대 대문자화하지 않지만, IMK 너머에서는 이 신호가 보이지 않는다.
- **전역 기본값이 ON**: `NSAutomaticCapitalizationEnabled` 미설정 시 true로 캐시되므로([ConfigurationManager.swift:318](../Sources/PriTypeCore/ConfigurationManager.swift#L318)) 사실상 모든 설치에서 발화한다. smart quote/dash 폴백도 같은 host-blind 경계를 공유한다(코드 파일 맨 앞에서 `'` → `'`).
- **문서 3곳이 유지보수를 오도**: UnifiedInputArchitecture invariant #5("영어 모드에서 printable key를 consume하지 않는다") + 같은 문서가 이 핸들러를 "dead code로 삭제했다"고 기록, ARCHITECTURE.md("순수 pass-through"), `ConfigurationManager` 주석("does not apply it"). 커밋 `45b68fb`가 스펙 갱신 없이 핸들러를 재도입했다. 문서만 믿고 #10을 디버깅하면 실제 원인을 배제하게 된다.
- **테스트가 버그를 고정**: N-10 참조.

**조치** — R-06의 권장(영어 printable 완전 pass-through 복원이 최선)과 동일. 어느 쪽을 택하든 invariant #5·ARCHITECTURE·주석·테스트를 같은 계약으로 일치시켜야 한다.

### N-06. 시스템 텍스트 편의 설정이 프로세스 시작 시 1회만 스냅숏된다

**근거** — [`ConfigurationManager.swift:314-329`](../Sources/PriTypeCore/ConfigurationManager.swift#L314)의 `cachedDoubleSpacePeriodEnabled`·`cachedAutoCapitalizationEnabled`·`cachedSmartQuoteSubstitutionEnabled`·`cachedSmartDashSubstitutionEnabled`는 init에서 한 번 읽힌 뒤 **어디에서도 다시 쓰이지 않는다**(전 코드베이스 grep으로 확인). 문서와 주석은 "macOS 설정을 미러링"한다고 말한다.

**영향** — N-05의 대문자화가 성가셔서 사용자가 시스템 설정 > 키보드에서 "자동으로 단어 대문자화"를 꺼도, **입력기는 로그아웃/재로그인 전까지 계속 대문자를 삽입한다**. 입력기는 수 주간 상주하는 프로세스라 "설정을 껐는데도 그대로"는 버그 신고로 직결된다. #10 수정 전까지의 임시 회피조차 막는 셈이라 N-05와 함께 처리해야 한다.

**조치** — `UserDefaults.didChangeNotification` 또는 KVO로 NSGlobalDomain 변경 시 캐시 갱신, 혹은 캐시 TTL. 스레드 경계는 기존 `systemTextFeatureLock` 유지.

### N-07. 한글 모드에서 Space가 무조건 소비된다

**근거** — [`HangulComposer.swift:234-244`](../Sources/PriTypeCore/HangulComposer.swift#L234): Space는 조합 유무와 무관하게 `commitComposition` → `delegate.insertText(" ")` → `return true`. 조합이 없어도 raw Space가 호스트에 도달하지 않는다.

**영향** — Space keyDown 자체에 의미를 두는 호스트 동작이 깨진다. 대표적으로 Finder에서 파일 선택 후 Space(Quick Look): 한글 모드에서는 immediate 모드 컨텍스트가 아닌 일반 목록 뷰에서 Quick Look 대신 아무 일도 일어나지 않거나 이름 편집이 시작될 수 있다. 웹 페이지의 Space 스크롤, 동영상 플레이어의 Space 재생/일시정지도 `insertText(" ")` 경로에서는 발화하지 않는 호스트가 있다.

**조치** — 조합이 비어 있으면(`context.isEmpty()` && 더블스페이스 판정 불요 시) `return false`로 pass-through. 더블스페이스 마침표 판정은 직전 키가 실제로 확정 입력이었던 경우로 한정.

### N-08. DEBUG 빌드가 Secure Input 게이트 이전에 원문 키 입력을 평문으로 기록

**근거** — [`PriTypeInputController.swift:374-379`](../Sources/PriTypeCore/PriTypeInputController.swift#L374): `handle()`의 디버그 로그(처음 200키)가 `chars='\(event.characters ?? "")'`를 포함하며, **4단계 Secure Input 게이트보다 앞서** 실행된다. `~/Library/Logs/PriType/pritype_debug.log`에 남는다.

**영향** — 릴리즈 빌드는 no-op이므로 최종 사용자 영향은 없다. 그러나 디버그 빌드를 도그푸딩하는 개발자는 SecurityAgent/비밀번호 필드에 입력한 내용 일부가 평문 파일로 남는다. 로그 파일을 이슈에 첨부하는 순간 유출된다.

**조치** — 로그 라인을 Secure Input 게이트 뒤로 이동하거나 `chars` 필드를 keyCode만 남기고 제거. 디버그 로그 안내 문서에 민감정보 주의 추가.

### N-09. 사전 로딩 중 한자키가 메인 스레드를 ~1초 블록 (심각도: 검증에서 high→medium 하향)

**근거** — [`HanjaManager.swift:25-52`](../Sources/PriTypeCore/HanjaManager.swift#L25): `loadIfNeeded()`가 `loadLock` 아래에서 6.4MB/80,000항목을 파싱한다(테스트 실측 ~1.15초). 시작 시 백그라운드 프리로드가 이 락을 잡은 동안 사용자가 한자키를 누르면 `search()` → `loadIfNeeded()`가 **메인 스레드에서 같은 락을 대기**한다.

**영향** — 앱 시작 후 첫 1초 안에 한자키를 누른 경우에 한정된 일회성 멈춤(입력기 전체 비프리즈)이라 검증 단계에서 medium으로 하향됐다. 다만 IME 메인 스레드 블록은 해당 호스트 앱의 키 입력 전체를 멈추므로 체감은 나쁘다.

**조치** — `isLoaded`를 락 밖에서 원자적으로 선확인하고, 미로딩 시 "로딩 중" 후보(빈 목록 + 안내) 반환 후 완료 콜백으로 재검색.

### N-10. 테스트가 버그를 정답으로 고정 — 외 검증 갭 3건

1. **[`HangulComposerTests.swift:144-157`](../Tests/PriTypeCoreTests/HangulComposerTests.swift#L144)** `englishModeAutoCapitalizationFallback`: 빈 필드에서 영어 `h`가 소비되고 `H`가 삽입되는 것을 **명시적으로 기대**한다 — Open #10의 증상 그 자체. #10을 고치면 이 테스트가 빨간불이 되어, 테스트를 통과시키려는 수정이 버그를 되살릴 위험이 있다. R-16의 "잘못된 검증이 회귀를 통과시킨다"의 실례.
2. **[`ClientContextTests.swift:161`](../Tests/PriTypeCoreTests/ClientContextTests.swift#L161)** Finder 데스크톱 판정 테스트가 실제 `analyze()`의 좌표 휴리스틱이 아닌 **테스트 내 사설 재구현**을 검증한다. 실물 로직이 바뀌어도 테스트는 통과한다.
3. **[`ConfigurationManagerTests.swift:124`](../Tests/PriTypeCoreTests/ConfigurationManagerTests.swift#L124)** KeyBinding 영속화 테스트가 getter 왕복만 검증하고 **UserDefaults 디코드·`ToggleKey`→`KeyBinding` 마이그레이션 경로를 실행하지 않는다**. 마이그레이션 회귀는 기존 사용자 전환키를 리셋시키는 부류의 버그다.
4. **[`UpdateCheckerTests.swift:50`](../Tests/PriTypeCoreTests/UpdateCheckerTests.swift#L50)** beta 채널 사용자가 상위 stable로 안내되는 경로와 malformed 태그 비교의 경계 검증 부재 (low, R-11과 연동).

---

## P3 — 후속 개선

### N-11. Secure Input 필드 속성 휴리스틱이 일반 경로에서 실행되지 않는다 (R-02 후속)

[`analyzeForActivation`](../Sources/PriTypeCore/ClientContextDetector.swift#L210)은 `hasTextInputCapability: !isFinder`로 **하드코딩**하고, non-Finder 앱 세션은 `deactivateServer` 이전까지 재분석되지 않는다. 따라서 ARCHITECTURE가 설명하는 2단계 게이트 중 "validAttributesForMarkedText 빈 배열 → 비밀번호 필드" 검사는 세션 첫 활성화 흐름에서 사실상 실행 기회가 없다(전역 Secure Input 플래그가 켜진 경우의 selection 프로브는 동작). `6d7b4a4`의 `SecureInputPolicy` 분리로 정책 자체는 테스트 가능해졌으므로, 남은 작업은 lightweight 컨텍스트에도 실제 capability를 공급하거나 문서에서 해당 단계 설명을 현행화하는 것이다. 검증 에이전트 2명 모두 "기술적으로 사실이나 실피해 경로는 제한적"으로 하향 판정.

### N-12. KeyEventDedup 50ms 창의 문자·수정자 무시

[`DirectInsertionPlanner.swift:22-31`](../Sources/PriTypeCore/DirectInsertionPlanner.swift#L22): 같은 keyCode의 비반복 keyDown이 50ms 내 재도달하면 무조건 중복 처리한다. 문자(Shift 조합)·수정자 차이를 비교하지 않으므로 이론상 20타/초 이상의 동일키 연타(게임, 자동화 입력)를 삼킬 수 있다. 인간 타이핑 범위 밖이라 low이나, snapshot에 `characters`·flags를 포함하면 위험이 0이 된다.

### N-13. Blink 분류와 직접 삽입 거부 목록의 드리프트 (실험 기능 한정)

[`blinkRendererBundleIds`](../Sources/PriTypeCore/ClientContextDetector.swift#L138)는 Whale·Vivaldi·Opera·Spotify(CEF)를 Blink로 알고 있지만, [`directInsertionDenied`](../Sources/PriTypeCore/ClientContextDetector.swift#L120)의 키워드 휴리스틱(`electron|chrome|chromium`)은 이 번들 ID들을 잡지 못한다. 실험 플래그를 켠 사용자가 Whale 등에서 직접 삽입을 시도하면 "Chromium 계열에는 신뢰 불가"라는 자체 원칙과 어긋난다. 두 목록이 같은 지식을 두 번 인코딩하고 있으므로 Blink 분류를 거부 판정의 입력으로 재사용하면 드리프트가 구조적으로 사라진다.

### N-14. `cleanupStaleInputSources`의 snapshot read-modify-write

[`InputSourceManager.swift:85-128`](../Sources/PriTypeCore/InputSourceManager.swift#L85)가 detached task에서 `com.apple.HIToolbox` plist를 읽고-수정-쓰는 동안 시스템(TIS/사용자 설정 변경)이 같은 키를 갱신하면 그 변경이 유실될 수 있다. 시작 시 1회 실행이라 창이 좁아 low. R-07 수정 시 같은 저장소를 다루므로 함께 정리 권장.

### N-15. 접근성 권한 회수→재부여 시 죽은 탭이 복구되지 않을 수 있음 (분쟁 항목)

설정의 재시작 가드는 [`!RightCommandSuppressor.shared.isRunning`](../Sources/PriTypeCore/SettingsWindowController.swift#L672)이고 `isRunning`은 단순히 `eventTap != nil`이다. 권한 회수 시 macOS가 기존 탭을 죽이되 disable 알림을 3회/60초 미만으로만 전달하면(또는 전달하지 않으면) `EventTapFailureTracker`의 handoff가 발동하지 않아 `eventTap`이 살아있는 것처럼 남고, 재부여 후에도 전환키가 죽은 채 설정은 초록 "허용됨"을 표시한다. **검증 1:1 분쟁**: 반박 측은 dead-tap에도 disable 알림이 전달되어 handoff→복구가 동작한다고 보았고, 지지 측은 권한 회수 시 무통지 사망이 통상 관찰되는 동작이라 보았다. 실기기에서 회수→재부여 시나리오를 직접 확인한 뒤, `isRunning`을 `CGEvent.tapIsEnabled` 실측으로 바꾸는 저비용 방어를 권장한다(README가 권한 껐다-켜기를 공식 트러블슈팅으로 안내하므로 실사용 경로다).

---

## Open 이슈 대응

| Open 이슈 | 이 리뷰의 판정 |
| --- | --- |
| [#10 영문 전환한뒤 첫글자가 대문자로 타이핑됨](https://github.com/Meapri/PriType-Swift/issues/10) | **코드 경로 확정** (N-05=R-06). 4개 차원 독립 도달 + 검증 2/2 + 본 세션 직접 추적. "특정 입력창" = 유효 selectedRange를 보고하는 호스트의 캐럿 0. 테스트(N-10-1)가 증상을 고정 중이므로 수정 시 테스트 교체 필수. |
| [#9 ABC 입력소스 끄기 후 다시 살아남](https://github.com/Meapri/PriType-Swift/issues/9) | **R-07(불완전 plist 편집·layout-ID variant/Selected/History 미정리·무검증 성공) 재확인.** 경쟁 가설 "PriType 모드가 ASCII-capable 미선언이라 macOS가 ABC를 강제 복원"은 검증 단계의 라이브 TIS 프로브로 **반박**: `com.pritype.inputmethod.v2.english`는 `tsInputModeScriptKey=smRoman`에서 ASCII-capable=true로 파생되며, ABC 없는 상태가 실제로 유지됨을 실측. 따라서 Info.plist에 `tsInputModeIsASCIICapableKey`를 추가하는 것은 #9의 해법이 아니다. |

## 부록 — 반박된 주장 7건

억지 이슈 억제 장치가 실제로 걸러낸 항목들. 특히 1–5번은 `6d7b4a4`·`eb459db` 수정의 유효성을 독립 확인한 셈이다.

1. "직접 삽입 finalize가 marked fallback 상태에서 음절을 유실" — 현재 코드는 `requiresMarkedTextFinalize`를 확인하고 marked finalize로 위임함 (eb459db에서 해결).
2. "caret 이동 시 직접 삽입이 엔진 flush 없이 tracking만 폐기" — 현재 코드는 매 키 전 `prepareForInput()`으로 flush함 (eb459db의 State enum 재설계).
3. "IOKit 인계 후 CGEventTap 재활성화로 이중 토글" (mode-switching) — 인용한 주석·코드가 현재 저장소에 존재하지 않음. `.handoffToIOKit`은 `stop()` 후 콜백.
4. 동일 주장 (concurrency 차원) — 동일 사유.
5. 동일 주장 (robustness 차원) — 동일 사유.
6. "Secure Input 테스트 4건이 dead code를 검증" — `SecureInputPolicy.shouldPassThrough`는 `handle()` 매 키마다 호출되는 live code (6d7b4a4 분리 이후 기준).
7. "InputSession.finalize 6개 사유 전부 테스트 0건" — `DirectInsertionTests`의 `FakeIMKTextInput` 기반 세션 테스트가 존재. (단, marked-text 경로의 finalize reason 매트릭스는 여전히 얇음 — 후속 보강 여지는 유효.)

## 한계

- 실기기 end-to-end(IMK 등록, TCC, KakaoTalk/Chromium별 동작, VoiceOver, 다중 모니터)는 수행하지 못했다. N-15는 실기기 확인이 선행돼야 한다.
- 리뷰 진행 중 HEAD가 `5faf944`→`eb459db`로 이동했다. 모든 확정 발견은 최종 HEAD 기준으로 재검증했으나, 1차 발견 단계의 일부 근거 라인 번호는 ±수 라인 오차가 있을 수 있다.
