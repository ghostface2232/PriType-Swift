# PriType 프로젝트 종합 리뷰 — 2026-07-21

## 결론

현재 코드에는 즉시 수정 계획을 잡아야 할 P1 5건, 다음 릴리즈 전에 처리할 P2 11건, 후속 품질 개선 P3 4건이 확인됐다. 억지로 이슈 수를 늘리지 않고, 코드의 실제 실행 경로가 성립하거나 현재 사용자 신고와 직접 연결되는 항목만 남겼다.

가장 먼저 다룰 문제는 다음과 같다.

1. 공개 PR의 코드를 릴리즈와 같은 종류의 self-hosted runner에서 실행하는 공급망 경계
2. stale Secure Event Input 전역 상태가 정상 필드의 한글 입력까지 차단하는 경로
3. 실험적 직접 삽입의 런타임 fallback에서 텍스트 중복·오염·유실이 가능한 상태 모델
4. CGEventTap 장애 인계 뒤 CGEventTap과 IOKit이 동시에 한/영을 전환하는 경로
5. 한자 후보창이 `⌘1` 같은 수정자 단축키를 후보 선택으로 처리하는 경로

현재 Open 이슈인 [#9 ABC 입력소스 끄기 후 다시 살아남](https://github.com/Meapri/PriType-Swift/issues/9)과 [#10 영문 전환한뒤 첫글자가 대문자로 타이핑됨](https://github.com/Meapri/PriType-Swift/issues/10)은 모두 코드 수준의 강한 원인이 확인됐다. 각각 R-07과 R-06에 정리했다.

## 범위와 방법

- 기준 커밋: `5faf944` (`main`, 2026-07-21 확인)
- 대상: 프로젝트 문서, SwiftPM 구성, IMK 입력 처리, 한/영 전환, 한자 UI, 설정·접근성·현지화, 테스트, 빌드·서명·릴리즈 워크플로
- 병렬 리뷰:
  - 코어 런타임·동시성·텍스트 무결성
  - UX·SwiftUI/AppKit·접근성·현지화
  - 테스트·패키징·릴리즈·공급망
- 교차검증: 각 결과를 현재 코드의 호출 순서, 상태 전이, 테스트 기대값, 관련 git history와 대조했다. 실기기나 호스트 동작에 따라 반증될 수 있는 항목은 조건을 명시하거나 우선순위를 낮췄다.
- 현재 Open 이슈는 GitHub connector 기준 #9와 #10만을 사용했다. 과거 검색 캐시에 노출된 닫힌 이슈는 현재 Open으로 간주하지 않았다.

우선순위 정의:

- **P0**: 즉시 배포 중단 또는 긴급 대응이 필요한 확정 사고. 이번 리뷰에서는 없음.
- **P1**: 보안 경계, 텍스트 무결성, 핵심 입력 불능 또는 사용자 데이터 변경 가능성. 수정 전까지 관련 기능/릴리즈를 막아야 함.
- **P2**: 재현 가능한 주요 기능·UX·릴리즈 신뢰성 문제. 다음 릴리즈 전에 처리 권장.
- **P3**: 범위가 제한된 품질·유지보수·접근성 문제. 계획된 후속 개선에 포함.

## 현재 구조 이해

PriType은 macOS 14 이상을 대상으로 하는 Swift 6.2 기반 InputMethodKit 입력기다. `PriType` 실행 타깃이 `IMKServer`와 전역 키 감시를 시작하고, `PriTypeCore`가 입력 세션·한글 조합·텍스트 전달·설정·한자 후보 UI를 담당한다. 한글 조합은 `libhangul-swift`에 위임한다.

현재 핵심 입력 흐름은 다음과 같다.

`PriTypeInputController` → `InputSession` → `HangulComposer` → `MarkedTextAdapter` / `DirectInsertionAdapter` / `ImmediateModeAdapter`

중요한 현재 사실은 `Info.plist`가 한국어 `smKorean`과 영어 `smRoman` 두 입력 모드를 등록한다는 점이다. 이는 단일 입력 모드라고 설명하는 README·ARCHITECTURE·설계 문서 일부와 다르다. 문서 불일치는 R-16에서 별도로 다룬다.

## 우선순위 요약

| ID | 우선순위 | 영역 | 요약 | 확신도 |
| --- | --- | --- | --- | --- |
| R-01 | P1 | 공급망 | 공개 PR 임의 코드를 영속 self-hosted runner에서 실행 | 높음 |
| R-02 | P1 | 핵심 입력 | stale Secure Event Input이 정상 필드 한글 입력도 차단 | 높음, 실기기 회귀 필요 |
| R-03 | P1 | 텍스트 무결성 | 직접 삽입 fallback에서 중복·오염·유실 가능 | 높음, 실험 기능 한정 |
| R-04 | P1 | 한/영 전환 | CGEventTap→IOKit 인계 뒤 두 감시기가 동시 토글 | 높음 |
| R-05 | P1 | 한자/단축키 | 후보창이 `⌘1` 등을 후보 선택으로 소비 | 높음 |
| R-06 | P2 | Open #10 | 영어 fallback이 필드 정책을 무시하고 대문자를 직접 삽입 | 높음 |
| R-07 | P2 | Open #9 | ABC 제거가 일부 상태만 수정하고 성공을 검증하지 않음 | 높음 |
| R-08 | P2 | 한/영 전환 | IOKit fallback이 일반키·조합키 binding을 지원하지 않음 | 높음 |
| R-09 | P2 | 한자 UX | 앱/Space 전환 뒤 최상위 후보 패널이 남을 수 있음 | 높음 |
| R-10 | P2 | 한자 위치 | 전역·무기한 cursor rect 캐시가 다른 앱 위치를 재사용 | 높음 |
| R-11 | P2 | 릴리즈 | beta 태그가 정식 GitHub Release로 게시됨 | 높음 |
| R-12 | P2 | 릴리즈 | 태그 경로에 테스트가 없고 필수 리소스 복사가 fail-open | 높음 |
| R-13 | P2 | 공급망 | 서명 키가 열린 동안 mutable third-party action 실행 | 높음 |
| R-14 | P2 | 접근성 | 한자 후보창의 VoiceOver 선택·공지 모델 부재 | 중간, 실기기 확인 필요 |
| R-15 | P2 | 현지화 | 영어 환경에 한국어 UI가 혼재하고 표시명이 저장됨 | 높음 |
| R-16 | P2 | 문서/테스트 | 현재 dual-mode·영문 동작과 정식 문서·검증 설명이 충돌 | 높음 |
| R-17 | P3 | 권한 UX | 접근성 권한 거부 시 복구 경로가 약하고 1 Hz poll이 지속 | 높음 |
| R-18 | P3 | 입력 상태 | 좌·우 동일 modifier 동시 사용 시 toggle 상태 고착 가능 | 높음 |
| R-19 | P3 | 설정 접근성 | 일부 switch/key recorder의 접근성 이름이 불명확 | 높음 |
| R-20 | P3 | 프로젝트 품질 | LICENSE 부재와 기여·테스트 문서의 오래된 정보 | 높음 |

## P1 — 우선 수정

### R-01. 공개 PR의 임의 코드를 영속 self-hosted runner에서 실행한다

**근거**

- [`.github/workflows/ci.yml`](../.github/workflows/ci.yml#L3)은 public fork PR을 받고, build와 lint 모두 단순 `self-hosted` runner를 사용한다.
- 같은 runner에서 PR이 바꿀 수 있는 `swift test`와 `swift run PriTypeVerify`를 실행한다([ci.yml](../.github/workflows/ci.yml#L20)).
- 릴리즈도 별도 label이나 runner group 구분 없이 `self-hosted`를 사용한다([release.yml](../.github/workflows/release.yml#L11)).

**영향**

승인된 PR workflow에서 공격자 코드가 runner 권한으로 실행된다. 영속 runner가 오염되면 뒤이은 릴리즈 빌드, Developer ID 서명, 공증 자격증명과 배포 산출물까지 영향을 받을 수 있다. fork PR에 secret이 직접 전달되지 않는다는 기본 보호는 실행 호스트의 영속 오염을 막지 않는다.

**권장 조치 및 검증**

PR은 GitHub-hosted macOS runner 또는 작업마다 폐기하는 JIT runner로 옮긴다. 서명 runner는 전용 runner group과 custom label로 격리하고 승인된 release workflow만 접근하게 한다. 악성 테스트가 파일·프로세스를 남겨도 다음 작업에 남지 않는지 검증한다.

### R-02. stale Secure Event Input이 정상 필드의 한글 입력도 차단한다

**근거**

- [`PriTypeInputController.shouldPassThroughSecureInput`](../Sources/PriTypeCore/PriTypeInputController.swift#L401)은 `IsSecureEventInputEnabled()`가 true이면 현재 필드의 capability나 selection을 확인하기 전에 즉시 pass-through한다.
- 이후 [`InputSession.discardForSecureInput`](../Sources/PriTypeCore/InputSession.swift#L201)은 클라이언트의 marked text를 finalize하지 않고 composer 상태만 버린다.
- 반면 [ARCHITECTURE](../ARCHITECTURE.md#L211)는 일부 앱이 전역 flag를 해제하지 않는 알려진 상황에서 정상 marked-text 필드는 stale flag로 판단해 계속 처리한다고 설명한다.

**영향**

다른 앱이 Secure Event Input을 잘못 유지하면 정상 앱에서도 한글 모드인 채 로마자가 입력된다. 전환 전에 조합 중이었다면 클라이언트의 marked preedit이 남을 가능성도 있다. 보안 필드에서 무조건 pass-through해야 한다는 요구는 맞지만, 전역 flag만으로 현재 필드의 소유·보안 여부를 확정할 수 없다.

**권장 조치 및 검증**

controller와 테스트가 하나의 pure secure-input policy를 실제로 공유하도록 한다. system secure client, invalid selection, capability 부재는 계속 fail-closed로 pass-through하되, 정상 marked-text capability가 확인된 새 앱/필드에서 stale global flag를 안전하게 복구하는 규칙을 별도로 둔다. 비밀번호 필드 보호와 stale flag 정상 필드를 함께 실기기 회귀 테스트한다.

### R-03. 실험적 직접 삽입의 fallback 상태가 텍스트를 중복·오염·유실할 수 있다

**근거**

- [`DirectInsertionAdapter.rewriteLivePreedit`](../Sources/PriTypeCore/TextDelivery.swift#L247)은 caret이 이동했을 때 새 caret 바로 앞 문자열이 이전 preedit과 같은지만 확인한다. 원래 live range의 위치·identity는 저장하지 않는다.
- runtime `selectedRange`가 invalid이면 이전 real preedit을 문서에 둔 채 tracking만 버리고 새 합성 결과를 marked fallback으로 렌더한다([TextDelivery.swift](../Sources/PriTypeCore/TextDelivery.swift#L271)).
- `fellBackToMarked == true`여도 [`InputSession.finalize`](../Sources/PriTypeCore/InputSession.swift#L157)는 adapter 타입만 보고 “이미 real text”로 판단해 commit을 생략한다.

**영향**

첫 자모가 real text로 들어간 뒤 range 조회가 실패하면 기존 자모와 새 marked syllable이 함께 남아 `ㄱ가`처럼 중복될 수 있다. caret을 동일 문자열 뒤로 옮기면 무관한 문자를 live region으로 오인해 덮어쓸 수 있다. marked fallback 뒤 focus/mode 전환에서는 조합이 유실되거나 stranded될 수 있다. 기본값이 꺼진 실험 기능에 한정되지만 텍스트 무결성 문제이므로 해당 기능의 release blocker로 본다.

**권장 조치 및 검증**

adapter에 `idle` / `directLive(range, text)` / `markedFallback` 상태를 명시하고 finalize를 adapter 상태가 결정하게 한다. caret 이탈이나 range invalid 시 기존 real text를 확정하고 composer를 flush/reset한 뒤 현재 키를 새 조합으로 처리한다. fake `IMKTextInput`으로 caret 이동, 동일 문자열 ABA, mid-composition invalid range, fallback 후 focus/mode finalize를 통합 테스트한다.

### R-04. CGEventTap 장애 인계 뒤 CGEventTap과 IOKit이 동시에 토글한다

**근거**

- 세 번 disable되면 [`RightCommandSuppressor`](../Sources/PriTypeCore/RightCommandSuppressor.swift#L136)는 `onTapFailed`를 호출하지만 같은 분기에서 event tap을 다시 enable한다.
- [`main.swift`](../Sources/PriType/main.swift#L88)의 callback은 IOKit을 추가로 시작한다. 기존 tap을 중지하거나 handoff를 exactly-once로 만드는 상태가 없다.

**영향**

CGEventTap이 회복되면 기본 우측 Command 한 번에 CG tap key-down과 IOKit key-up이 각각 전환을 요청해 `한글 → 영어 → 한글`이 된다. 사용자에게는 전환키가 죽은 것처럼 보인다. 장애 callback도 다시 호출될 수 있다.

**권장 조치 및 검증**

handoff 임계점에서 run-loop source와 CG tap을 완전히 중지한 다음 IOKit을 한 번만 시작한다. 반대로 CG tap 재시도 정책을 유지한다면 IOKit을 중지한 후에만 재활성화한다. 감시기 소유권을 단일 state machine으로 만들고 한 physical press당 callback이 정확히 한 번인지 테스트한다.

### R-05. 한자 후보창이 수정자 단축키를 후보 선택·이동으로 처리한다

**근거**

- [`HangulComposer.handle`](../Sources/PriTypeCore/HangulComposer.swift#L393)은 후보창 처리를 Command/Control/Option pass-through보다 먼저 실행한다.
- [`HanjaCandidateWindow.handleKey`](../Sources/PriTypeCore/HanjaCandidateWindow.swift#L130)는 modifier를 버린 `charactersIgnoringModifiers`와 keyCode만 사용한다.

**영향**

후보창이 열린 동안 `⌘1`은 1번 후보를 선택해 문서를 바꾸고, `⌘Tab`, `⌘[`, `⌘↓` 같은 단축키도 후보 페이지 동작으로 소비될 수 있다. 같은 함수의 “system shortcuts work correctly”라는 의도와 실행 순서가 직접 충돌한다.

**권장 조치 및 검증**

modifier pass-through를 후보 라우팅보다 먼저 수행한다. 후보창은 modifier 없는 숫자·화살표·Tab·Enter·Escape만 받게 하고, `⌘1`, `⌃1`, `⌥1`, `⌘Tab`이 문서를 바꾸지 않고 host로 전달되는 회귀 테스트를 추가한다.

## P2 — 다음 릴리즈 전 처리

### R-06. Open #10: 영어 fallback이 필드별 정책을 무시하고 대문자를 직접 삽입한다

**근거**

- 영어 모드도 [`TextConvenienceHandler`](../Sources/PriTypeCore/HangulComposer.swift#L372)를 거친다.
- [`handleAutoCapitalization`](../Sources/PriTypeCore/TextConvenienceHandler.swift#L157)은 전역 설정이 켜져 있고 cursor 앞이 비었거나 문장 경계면 lowercase event를 소비하고 uppercase를 직접 삽입한다.
- 현재 테스트도 첫 `h`가 `H`가 되는 동작을 명시적으로 기대한다([HangulComposerTests](../Tests/PriTypeCoreTests/HangulComposerTests.swift#L144)).
- 반면 README와 ARCHITECTURE, `ConfigurationManager` 주석, `PriTypeVerify`는 영어 모드를 순수 pass-through라고 설명·검증한다.

**영향**

주소, 검색, 코드, 계정명처럼 host가 자동 대문자를 끈 필드에서도 첫 글자가 사용자가 누르지 않은 대문자로 바뀐다. 이는 [Open #10](https://github.com/Meapri/PriType-Swift/issues/10)의 빈 필드와 문장 뒤 첫 글자 증상에 정확히 대응한다. smart quote/dash/double-space fallback도 동일한 전역-only 경계를 공유한다. 시스템 설정도 singleton 초기화 때 캐시되어 실행 중 변경이 반영되지 않는다.

**권장 조치 및 검증**

가장 안전한 수정은 영어 printable key를 완전 pass-through로 되돌려 host가 필드 정책을 소유하게 하는 것이다. fallback을 유지해야 한다면 host/field opt-in 신호가 검증된 곳으로 제한한다. #10에는 빈 일반 필드, URL/search/code 성격 필드, 문장 뒤 lowercase가 모두 직접 삽입되지 않는 테스트를 연결한다.

### R-07. Open #9: ABC 제거가 불완전한 preferences 상태만 바꾸고 성공을 검증하지 않는다

**근거**

- [`removeABCKeyboard`](../Sources/PriTypeCore/SettingsWindowController.swift#L617)는 `AppleEnabledInputSources`에서 `KeyboardLayout Name == "ABC"`만 제거한다.
- layout ID 252만 가진 variant, `AppleSelectedInputSources`, `AppleInputSourceHistory`는 이 동작에서 처리하지 않는다. 같은 저장소의 [`InputSourceManager`](../Sources/PriTypeCore/InputSourceManager.swift#L85)는 세 배열이 모두 존재함을 이미 알고 있다.
- sync 반환값과 `killall` 오류·종료 상태를 버리고 TIS를 재조회하지 않은 채 무조건 `.success`를 표시한다.
- 과거 `4560ee7` 구현은 이름과 layout ID, selected sources를 처리했으므로 현재 단순화 과정에서 보호 범위가 줄었다.

**영향**

HIToolbox/TextInputMenuAgent가 남은 selected/history 상태에서 ABC를 다시 만들 수 있고, 실패해도 UI는 “완료”로 보인다. [Open #9](https://github.com/Meapri/PriType-Swift/issues/9)의 성공 표시 후 재등장과 일치한다.

**권장 조치 및 검증**

가능하면 지원되는 시스템 설정/TIS 흐름으로 제한한다. 기능을 유지한다면 name+ID로 관련 상태를 일관되게 정리하고, agent refresh 뒤 TIS enabled sources를 지연 재조회해 postcondition으로 성공을 판단한다. macOS가 로그인/FileVault용 Roman fallback을 복원하는 정책이면 기능을 제거하거나 제한을 명확히 안내한다.

### R-08. IOKit fallback은 UI가 허용하는 일반키·조합키 binding을 지원하지 않는다

**근거**

- [`IOKitManager.hidUsage`](../Sources/PriTypeCore/IOKitManager.swift#L52)는 modifier와 Caps Lock만 매핑한다.
- toggle 처리도 `toggleBinding.isModifierOnly`일 때만 진입한다([IOKitManager.swift](../Sources/PriTypeCore/IOKitManager.swift#L171)).
- 반면 CGEventTap과 설정 UI는 F13 같은 일반키와 Control+Space/Option+G 같은 조합을 허용한다.

**영향**

CG tap 생성 실패나 R-04의 올바른 hard handoff 순간, 해당 custom binding은 아무 경고 없이 영구 중단된다. 한자 binding도 같은 제한을 받는다.

**권장 조치 및 검증**

전체 virtual key↔HID usage와 modifier chord 상태를 구현하거나 fallback에서 지원할 수 있는 binding만 UI에서 허용한다. 일반키, modifier-only, chord, toggle/hanja 충돌 조합을 matrix 테스트한다.

### R-09. 앱/Space 전환 뒤 최상위 한자 후보 패널이 남을 수 있다

**근거**

- 후보창은 `screenSaver + 1`, `hidesOnDeactivate = false`, 모든 Space 참여로 설정되고 `orderFrontRegardless()`로 열린다([HanjaCandidateWindow.swift](../Sources/PriTypeCore/HanjaCandidateWindow.swift#L67)).
- 앱 deactivation observer는 composition만 finalize하며([InputSession.swift](../Sources/PriTypeCore/InputSession.swift#L111)), controller deactivate도 후보창을 닫지 않는다([PriTypeInputController.swift](../Sources/PriTypeCore/PriTypeInputController.swift#L267)).

**영향**

후보창을 연 채 다른 앱·Space·전체화면으로 이동하면 이전 입력 컨텍스트의 패널이 새 앱 위에 남을 수 있다. 다음 일반 키가 composer에 오면 닫히지만 PriType이 비활성인 동안에는 그 이벤트 자체가 오지 않을 수 있다.

**권장 조치 및 검증**

session/app deactivate와 client identity 변경 시 후보 상태와 패널을 함께 dismiss한다. window level과 모든 Space 참여가 실제 호환성에 필요한 최소값인지 다시 측정한다.

### R-10. cursor rect 캐시가 다른 앱·화면의 위치를 무기한 재사용한다

**근거**

- [`CursorRectResolver.lastKnownCursorRect`](../Sources/PriTypeCore/CursorRectResolver.swift#L18)는 client/app/window identity와 timestamp가 없는 전역 값이다.
- 새 client의 표준 좌표 API가 실패하면 현재 앱의 AX 조회보다 이 캐시를 먼저 사용한다([CursorRectResolver.swift](../Sources/PriTypeCore/CursorRectResolver.swift#L68)).

**영향**

앱 A/모니터 A에서 캐시된 좌표가 앱 B/모니터 B의 후보창 위치가 될 수 있다. 화면 안 clamp는 창이 완전히 사라지는 것은 막지만 현재 caret 근처라는 기능 계약은 깨진다.

**권장 조치 및 검증**

캐시를 client/app/window identity와 짧은 TTL에 묶고, app deactivate·client 교체·display configuration 변경에서 지운다. 가능한 경우 현재 앱의 AX 결과를 stale cache보다 먼저 사용한다.

### R-11. beta 태그가 정식 GitHub Release로 게시된다

**근거**

- release workflow는 `v3.0.0-beta.1` 같은 태그를 beta channel로 정상 허용한다([release.yml](../.github/workflows/release.yml#L22)).
- 그러나 `softprops/action-gh-release`에 `prerelease`나 `make_latest`를 전달하지 않는다([release.yml](../.github/workflows/release.yml#L93)).
- README 설치 링크는 `/releases/latest`다([README.md](../README.md#L40)).

**영향**

beta가 GitHub UI에서 정식 최신 릴리즈가 되어 일반 설치 사용자가 beta를 받을 수 있다. 앱의 `UpdateChecker`가 tag marker로 stable channel을 보호하는 것은 README/GitHub의 latest 링크를 보호하지 않는다.

**권장 조치 및 검증**

hyphenated version에는 `prerelease: true`, `make_latest: false`를 명시하고 stable에만 latest를 부여한다. release 생성 뒤 API로 channel/latest 상태를 확인한다.

### R-12. 태그 릴리즈 경로에 테스트가 없고 필수 리소스 복사가 fail-open이다

**근거**

- 일반 CI는 branch push/PR만 대상으로 하므로 tag push 자체에는 실행되지 않는다([ci.yml](../.github/workflows/ci.yml#L3)).
- release workflow는 build/sign/notarize만 실행하고 `swift test`와 `PriTypeVerify`를 실행하지 않는다([release.yml](../.github/workflows/release.yml#L90)).
- [`build_release.sh`](../build_release.sh#L48)은 resources와 아이콘 복사를 `|| true`로 무시하고 SwiftPM resource bundle이 없으면 조용히 건너뛴다.

**영향**

임의 commit에 버전만 맞춰 태그하거나 build output 구조가 바뀌면 테스트 실패 또는 한자 사전·현지화·아이콘이 빠진 PKG도 서명·공증되어 게시될 수 있다.

**권장 조치 및 검증**

release job에서 unit/verify를 필수 실행하거나 같은 SHA의 required CI 성공을 검증한다. 필수 resource는 `test -f/-d`로 fail-closed 처리하고, 최종 PKG를 expand하여 사전 검색·localization·plist asset·codesign을 smoke test한다.

### R-13. 서명 키가 열린 동안 mutable third-party release action을 실행한다

**근거**

- release job은 P12를 `-A`로 임시 keychain에 import하고 공증 profile을 저장한다([release.yml](../.github/workflows/release.yml#L49)).
- cleanup 전에 이동 가능한 tag인 `softprops/action-gh-release@v2`를 실행한다([release.yml](../.github/workflows/release.yml#L93)).

**영향**

upstream action tag가 탈취·이동되면 action이 열린 Developer ID 키와 공증 profile을 사용해 임의 산출물을 서명·게시할 수 있다. 가능성은 R-01보다 낮지만 성공 시 피해가 크다.

**권장 조치 및 검증**

third-party action을 검증된 full commit SHA로 고정한다. 서명 job은 keychain/P12/profile을 제거하고 digest가 있는 artifact만 내보내며, 별도 GitHub-hosted job이 업로드하도록 경계를 분리한다.

### R-14. 한자 후보창의 VoiceOver 선택·공지 모델이 부족하다

**근거**

- 후보 UI의 각 행은 SwiftUI `Button`이지만 현재 선택 인덱스, selected trait, 후보창 열림·페이지 변경 announcement가 없다([HanjaCandidateWindow.swift](../Sources/PriTypeCore/HanjaCandidateWindow.swift#L329)).
- nonactivating panel이고 키보드의 위/아래도 행 이동이 아니라 페이지 이동만 한다.

**영향**

VoiceOver 사용자는 후보창이 열렸는지, 숫자 1–9가 어느 후보와 연결되는지, 현재 선택이 무엇인지 파악하기 어렵다. 기본 Button AX element가 생성된다는 완화 요소가 있어 실제 VoiceOver 검증 후 세부 동작을 확정해야 한다.

**권장 조치 및 검증**

표준 위/아래 행 이동, Enter 선택, selected trait을 추가한다. 각 행을 “1, 可, 옳을 가”처럼 결합해 읽고 창 열림·선택·페이지 변경을 공지한다. VoiceOver와 Full Keyboard Access로 검증한다.

### R-15. 영어 환경에 한국어 UI가 섞이고 key display name이 locale과 함께 굳는다

**근거**

- 실험 기능([SettingsWindowController.swift](../Sources/PriTypeCore/SettingsWindowController.swift#L425)), 후보 footer([HanjaCandidateWindow.swift](../Sources/PriTypeCore/HanjaCandidateWindow.swift#L354)), IMK 메뉴([PriTypeInputController.swift](../Sources/PriTypeCore/PriTypeInputController.swift#L446)), status tooltip/AX label([StatusBarManager.swift](../Sources/PriTypeCore/StatusBarManager.swift#L52))에 한국어가 하드코딩돼 있다.
- [`KeyBinding`](../Sources/PriTypeCore/ConfigurationManager.swift#L77)은 표시용 한국어 문자열을 설정 데이터와 함께 저장하므로 locale을 바꿔도 기존 문자열이 남는다.
- ko/en strings 파일의 key 집합과 plist 문법은 정상이다. 문제는 localization table을 거치지 않는 UI다.

**영향**

영어 locale에서 설정·후보·입력기 메뉴가 혼합 언어로 나타나며 저장된 shortcut 이름은 앱 업데이트나 locale 변경만으로 고쳐지지 않는다.

**권장 조치 및 검증**

사용자 노출 문자열을 모두 L10n으로 이동한다. binding에는 keyCode/modifiers만 영속화하고 표시명은 현재 locale에서 생성한다. `ko`, `en`, locale 변경 후 기존 설정 migration을 snapshot/수동 점검한다.

### R-16. 현재 dual-mode·영문 동작과 정식 문서·검증 설명이 충돌한다

**근거**

- [`Info.plist`](../Info.plist#L27)와 [`RegistrationContractTests`](../Tests/PriTypeCoreTests/RegistrationContractTests.swift#L13)는 한국어/영어 두 모드를 명시한다.
- README는 “PriType 단일 입력 소스”라고 하고([README.md](../README.md#L63)), ARCHITECTURE는 `ComponentInputModeDict`에 단일 mode만 등록한다고 한다([ARCHITECTURE.md](../ARCHITECTURE.md#L100)). [`UnifiedInputArchitecture`](UnifiedInputArchitecture.md#L59)도 단일 모드를 정식 명세로 둔다.
- ARCHITECTURE와 `PriTypeVerify`는 영어 pure pass-through라고 하지만 실제 코드는 R-06의 변환을 수행한다.
- ARCHITECTURE는 121 tests/15 suites라고 하나 정적 집계는 현재 `@Test` 172개, `@Suite` 26개다.

**영향**

입력 소스 버그를 고칠 때 서로 다른 아키텍처를 기준으로 판단하게 되고, 잘못된 검증이 실제 회귀를 “통과”시킬 수 있다. 실제로 `PriTypeVerify`의 영어 검증은 uppercase `A/B`만 사용해 R-06을 보지 못한다.

**권장 조치 및 검증**

현재 의도한 registration과 English ownership을 먼저 한 문장으로 결정한다. README·ARCHITECTURE·UnifiedInputArchitecture·CHANGELOG·Verify를 같은 계약으로 갱신하고, 현재 `Info.plist`에서 자동 생성 가능한 contract/test 수치 외에는 고정 숫자를 제거한다.

## P3 — 후속 품질 개선

### R-17. 접근성 권한 거부 후 복구 경로가 약하고 launch poll이 계속된다

- [`main.swift`](../Sources/PriType/main.swift#L59)는 허용될 때까지 1초 repeating timer를 무기한 유지한다.
- 설정창의 재요청은 120초 후 멈추지만 Privacy & Security > Accessibility를 직접 여는 경로나 timeout 실패 상태를 제공하지 않는다([SettingsWindowController.swift](../Sources/PriTypeCore/SettingsWindowController.swift#L653)).
- 기본 전환키와 한자키가 동작하지 않는 사용자가 원인을 복구하기 어렵고, 장기 실행 입력기에서 불필요한 1 Hz wake가 남는다.
- 공용 bounded permission helper, system settings deep link, 거부/timeout 안내와 명시적 재시도를 제공한다.

### R-18. 좌·우 동일 modifier를 동시에 쓰면 toggle 상태가 고착될 수 있다

- [`RightCommandSuppressor`](../Sources/PriTypeCore/RightCommandSuppressor.swift#L202)는 physical keyCode와 aggregate modifier flag를 섞어 단일 boolean 상태를 관리한다.
- Left Command를 누른 채 Right Command를 눌렀다 떼면 aggregate `.maskCommand`가 남아 Right Command release를 놓칠 수 있다. 이후 shortcut에서 modifier를 제거하는 분기([RightCommandSuppressor.swift](../Sources/PriTypeCore/RightCommandSuppressor.swift#L291))가 잘못 적용될 수 있다.
- binding key의 physical down/up 상태를 keyCode 중심으로 추적하고 좌/우 동시 누름·release 순서를 테스트한다.

### R-19. 일부 설정 control의 접근성 이름이 불명확하다

- [`SettingsToggleRow`](../Sources/PriTypeCore/SettingsWindowController.swift#L919)는 빈 label의 `Toggle`에 `.labelsHidden()`을 사용하고 explicit accessibility label이 없다.
- key recorder는 현재 값은 보여도 “한/영 전환키 변경” 같은 목적과 recording hint가 충분히 연결되지 않는다.
- title을 control label로 결합하고 `accessibilityValue`·recording hint를 명시한다. 같은 파일의 `SelectionRow` AX 처리를 기준으로 삼을 수 있다.

### R-20. LICENSE와 기여·테스트 문서가 저장소 상태와 일치하지 않는다

- README는 MIT를 표시하지만 root에 `LICENSE`/`COPYING` 전문이 없다.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md#L5)는 `your-org` clone URL과 Xcode 15/Swift 6.0을 안내하지만 manifest는 Swift tools 6.2를 요구한다.
- ARCHITECTURE의 테스트 수와 BENCHMARK anchor도 현재 상태와 다르다.
- 정식 MIT 전문과 copyright를 추가하고 dependency notice를 확인한다. clone URL·toolchain·검증 명령은 CI와 같은 값을 사용한다.

## 현재 Open 이슈 대응표

| Open 이슈 | 판정 | 이 보고서의 처리 | 완료 조건 |
| --- | --- | --- | --- |
| [#9 ABC 입력소스 끄기 후 다시 살아남](https://github.com/Meapri/PriType-Swift/issues/9) | 구현 원인 강함 | R-07에 통합, 신규 중복 이슈 불필요 | 상태 변경 후 TIS 재조회, 재등장 시 실패 UI, reboot/login 포함 회귀 |
| [#10 영문 전환한뒤 첫글자가 대문자로 타이핑됨](https://github.com/Meapri/PriType-Swift/issues/10) | 코드 경로 확정 | R-06에 통합, 현재 기대 테스트가 오히려 회귀를 고정 | 영어 printable direct insertion 0회, URL/search/code/일반 필드 실기기 회귀 |

## 검증 결과와 한계

완료한 검증:

- 저장소의 모든 Swift 파일에 `swiftc -parse` 적용: 통과
- `Info.plist`, entitlements, ko/en `InfoPlist.strings`·`Localizable.strings`에 `plutil -lint`: 통과
- shell scripts 구문 검사: 통과
- 기존 `.build/out/Products/Debug/PriTypeVerify` 실행: 모든 내장 검증 통과
- git history로 #9 제거 로직의 과거 보호 범위와 현재 구현을 비교
- 문서·코드·테스트 contract 교차 비교

제약:

- 이 환경에는 `/Applications/Xcode.app`이 없고 Command Line Tools만 있다. `swift test`는 SwiftUI의 `@State` macro가 요구하는 `SwiftUIMacros` plugin을 찾지 못해 compile 단계에서 완료되지 않았다. 이는 프로젝트 테스트 실패로 판정하지 않았다.
- 실제 IMK 등록, TCC 권한, Secure Event Input, TextEdit/Safari/Chromium/KakaoTalk별 동작, VoiceOver, 다중 모니터·Space, 서명·공증 PKG는 이 환경에서 end-to-end 실행하지 못했다.
- 따라서 R-02와 R-14는 코드 근거가 강하지만 수정 전후 실기기 검증이 필수다. R-03은 실험 기능이므로 일반 기본 경로의 회귀와 분리해 테스트해야 한다.

## 권장 실행 순서

1. R-01/R-13으로 PR runner와 signing runner의 신뢰 경계를 먼저 분리한다.
2. R-05, R-04, R-02를 각각 작은 상태-machine/ordering 수정과 회귀 테스트로 처리한다.
3. 실험 직접 삽입은 R-03의 adapter 상태 모델과 fake client 통합 테스트가 끝날 때까지 노출을 유지하되 release-ready로 승격하지 않는다.
4. Open #10은 영어 pure pass-through 계약을 확정해 R-06을 수정하고, Open #9는 postcondition 기반으로 R-07을 수정한다.
5. R-08~R-16을 다음 릴리즈 gate에 포함하고, 마지막에 실기기 compatibility matrix를 수행한다.

권장 실기기 matrix는 macOS 14/15/26, TextEdit·Notes·Safari URL/search·Chrome/Electron·KakaoTalk, 한국어/영어 locale, VoiceOver on/off, 단일/다중 모니터, normal/secure field, CGEventTap 강제 disable, 일반키/조합키 binding을 포함한다.
