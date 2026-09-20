# 결정 히스토리

현재 코드가 왜 이런 모양인지에 대한 기록이다. **현재 동작의 설명은 [ARCHITECTURE.md](../ARCHITECTURE.md)에 있다** — 여기 적힌 것은 그때의 판단이고, 이후 달라진 것은 그쪽이 맞다.

여기 있던 계획서와 리뷰 문서들은 삭제했다. 각각 자기 시점의 코드를 기준으로 쓰였고, 그 시점이 지나면 읽는 사람에게 "이게 현행인가"를 먼저 묻게 만든다. 수정은 커밋에 남았고, 지켜야 할 불변식은 ARCHITECTURE.md와 코드 주석으로 옮겼다. 원문이 필요하면 `git log -- Docs/`로 꺼낼 수 있다.

---

## 2026-05 ~ 06 · 한/영 전환 구조

**2.7.x의 첫 글자 씹힘.** 전환키가 `TISSelectInputSource()`를 **전환 수단으로** 불렀다. 그 호출은 비동기라서 다음 keyDown이 아직 옛 모드를 본다.

두 가지 안을 검토했다. 하나는 영어용 가짜 입력 모드를 따로 등록하는 것(`InputArchitectureHybridRollbackPlan`, 2026-05-31), 다른 하나는 단일 소스 안에서 내부 상태만 바꾸는 것(`SingleIMECompensationPlan`, 2026-06-05). **후자로 수렴했다**: 전환은 `HangulComposer.inputMode`를 동기적으로 바꾸는 것이고, macOS에 대한 통보는 hot path 밖에서 결과만 알리는 것이다. 통보가 늦거나 실패해도 입력은 영향받지 않고 메뉴 막대 아이콘만 뒤따른다.

**지금도 유효한 불변식** — 전환 hot path에서 `TISSelectInputSource()`를 부르지 않는다. `selectInputMode:`도 쓰지 않는다(클라이언트를 경유하므로 Latin 전용 호스트를 실제 ABC로 넘길 수 있다). 자세한 순서는 ARCHITECTURE.md의 "전환 처리".

이후 달라진 것: `Info.plist`는 입력 모드 두 개(한국어·영문)를 등록한다. `StatusBarManager`와 `handleEnglishModeInput`은 2026-09에 삭제됐다.

## 2026-07 · 종합 리뷰와 교차검증

두 번의 리뷰(단독 리뷰 20건, 멀티에이전트 교차검증 35건 중 확정 15건)에서 나온 것 중 코드에 남은 것:

- CI와 릴리스를 GitHub-hosted VM으로 옮기고 공급망 경계를 문서화했다 → [ReleaseRunnerSecurity.md](ReleaseRunnerSecurity.md)
- stale한 전역 Secure Event Input이 정상 필드의 한글 입력까지 막던 경로를 `SecureInputPolicy`로 분리했다
- 직접 삽입 어댑터의 상태 모델을 enum으로 다시 세웠다
- CGEventTap → IOKit 인계를 `EventTapFailureTracker`로 정확히 한 번만 일어나게 했다
- 한자 후보창이 `⌘1` 같은 수정자 단축키를 후보 선택으로 처리하던 경로를 닫았다

교차검증이 앞선 수정을 역으로 검증한 사례가 있다. 1차 리뷰의 "인계 후 이중 토글", "직접 삽입 fallback 텍스트 중복/유실" 주장은 검증 단계에서 "현재 코드에 해당 경로 없음"으로 반박됐다.

## 2026-09-09 · 전환 뒤 영문만 입력되던 문제

앱을 옮긴 뒤 우측 Command를 눌러도 영문만 나오는 증상. 원인을 하나로 확정하지 않고 성립 가능한 경로를 모두 막았다.

- 빈 `validAttributesForMarkedText`를 "텍스트 입력 불가"의 근거로 쓰지 않는다. [Apple 문서](https://developer.apple.com/documentation/appkit/nstextinputclient/validattributesformarkedtext())상 이 목록은 지원 속성 이름이며, 비어 있다는 것이 비밀번호 필드의 증거가 아니다. 전역 보안 경고가 없으면 이 휴리스틱으로 차단하지 않는다.
- aggregate Command 플래그는 좌우를 구분하지 못한다. device-specific 플래그로 각 키를 추적하고, 탭 복구와 다음 keyDown에서 재동기화한다.
- 첫 keyDown에서도 공유 조합기의 활성 소유자를 등록하고, 이전 소유자의 observer를 해제한다.

## 2026-09-16 · ABC 레이아웃 제거 확인

macOS 27에서 "ABC 끄기"가 성공해도 항상 "실패"로 보고되던 문제. HIToolbox가 활성 입력 소스 목록을 **프로세스별로 영구 캐시**하기 때문이다 — `kTISNotifyEnabledKeyboardInputSourcesChanged` 게시, `TextInputMenuAgent` 재시작, 전체 재조회 어느 것으로도 갱신되지 않고, 새로 뜬 프로세스만 갱신된 상태를 본다. `TISDisableInputSource`는 마지막 키보드 레이아웃에 대해 `noErr`을 돌려주고 아무것도 바꾸지 않는다.

그래서 제거 확인은 `ABCLayoutStatusProbe`가 자기 실행 파일을 `--abc-layout-status`로 다시 띄워서 한다. 이 우회는 macOS의 동작이 바뀌기 전까지 필요하다.

## 2026-09-20 · 입력 정확성

기존 406개 테스트가 모두 통과하는 상태에서, 경계 조건 재현 6개 중 5개가 실패했다. 커버리지가 "위험한 곳"이 아니라 "대역으로 만들기 쉬운 곳"을 따라 자랐다는 뜻이다. 고친 것들은 `Tests/PriTypeCoreTests/ReviewFixRegressionTests.swift`에 각각 하나의 테스트로 남아 있다.

같은 판단에서 이어진 작업:

- **실기기 검증.** 합성 입력으로 도달할 수 없는 경로 — IOKit 대체 경로, 실제 탭 생성, 새 프로세스 프로브 — 를 실제 머신에 묻는 `pritype-device-check`를 만들었다. 이 자리에 있던 `PriTypeVerify`는 검사가 느슨해서(경고를 찍고 성공 반환, 릴리스에서 사라지는 단언, 실제 `UserDefaults` 오염) 제거했고, 그 실패 방식들이 새 도구의 설계 제약이 됐다. → [DeviceVerification.md](DeviceVerification.md)
- **탭 경계 동시성.** 탭 스레드와 HID 콜백이 닿는 타입들이 `@unchecked Sendable`이었다. 그중 `IOKitManager`는 아무것도 보호하고 있지 않았고, `ToggleExclusionPolicy`는 옵저버를 잠금 밖에 두고 있었다. `Guarded` 하나로 모으고 탭 경계의 여섯 타입을 검사받는 `Sendable`로 바꿨다(패키지의 나머지 `@unchecked`는 IMK 메인 스레드 타입들이고 그대로 남아 있다). → ARCHITECTURE.md "동시성"
