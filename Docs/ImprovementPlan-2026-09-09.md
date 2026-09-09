# PriType 안정화 실행 계획 및 결과 — 2026-09-09

## 목표와 판단

사용자가 보고한 증상은 앱/입력창 전환 뒤 우측 Command를 반복해서 눌러도 영문만 입력되는 것이다. 앱 이름과 OS에서의 재현 로그는 아직 없으므로 **실제 발생 원인을 하나로 확정하지 않는다**. 지정 리뷰 `MultiAgentReview-2026-07-21.md`를 먼저 읽고 현행 코드의 성립 여부를 다시 확인했다.

전체 구조를 다시 쓰기보다 기존 `HangulComposer → InputSession → TextDeliveryAdapter`를 유지하고, 전환·컨트롤러 소유권·보안 입력 판정 경계를 먼저 고친다. 등록 identity나 텍스트 교체 범위를 일괄 바꾸는 것은 배포 및 호스트별 검증 범위가 크므로 별도 단계로 둔다.

## 증상과 직접 관련된 경로 및 이번 수정

1. **빈 속성 목록의 오판 — N-11/R-02의 추가 발견.** `activateServer`의 lightweight 컨텍스트는 일반 앱을 capable로 가정하지만 재진입 후 `analyze()`는 빈 `validAttributesForMarkedText`를 incapable로 저장했다. 기존 SecureInputPolicy는 전역 보안 입력이 꺼져 있어도 이를 이유로 계속 false를 반환했다. 모드는 한글로 전환되지만 매 키가 우회되므로 영문만 나온다. [Apple API 계약](https://developer.apple.com/documentation/appkit/nstextinputclient/validattributesformarkedtext())에서 이 목록은 지원하는 속성 이름이며 빈 값은 텍스트 입력 불가/비밀번호 필드의 증거가 아니다. 전역 보안 경고가 없으면 이 휴리스틱으로 차단하지 않도록 수정했다. 시스템 보안 클라이언트와 전역 경고+불확실한 필드의 우회는 유지한다.
2. **우측 Command 고착 — N-03.** aggregate Command 플래그는 좌우를 구분하지 못한다. device-specific 플래그로 각 키를 추적하고, 탭 복구와 다음 keyDown에서 재동기화한다. 왼쪽 Command가 함께 눌렸으면 aggregate Command를 보존한다.
3. **공유 composer와 지연된 컨트롤러 콜백.** 첫 keyDown에서도 활성 소유자를 등록하고, 이전 소유자의 focus/layout observer를 해제한다. 이전 소유자의 finalize/레이아웃 변경은 새 조합을 건드리지 않는다. 중복 activate는 동일 세션을 보존한다. 비활성 컨트롤러에 온 모드 알림은 보류하되, 이후 명시적 모드 선택이 있으면 세대 번호로 폐기한다.
4. **전환이 실제 ABC로 세션을 넘기는 경로 — 원본 PR #11 참고.** 사용자 전환의 `selectInputMode:`를 제거한다. 내부 composer와 PriType 자체 상태 표시만 갱신한다. 영어 키보드 override는 이미 활성화된 ABC/US에 한정하고 영어 모드에서만 수행한다. 이로 인해 macOS 자체 입력 소스 표시와 내부 모드 표시가 다를 수 있으며, 시스템 모드 선택/Caps Lock은 기존 `setValue` 경로를 유지한다.

빈 속성의 IMK 테스트 대역으로 활성화→재분석→영/한 전환→`가` 조합을 세 번 실행해 `가가가`를 확인했다. CGEvent 테스트는 실제 suppressor 진입점에 우측 Command 누름→탭 비활성화→왼쪽 Command+C→다음 우측 Command 누름을 전달한다. 실제 OS/TCC/호스트 연결을 대체하는 테스트는 아니다.

## 지정 리뷰 처리표

| 항목 | 이번 처리 | 남은 검증/후속 |
|---|---|---|
| N-01 | preedit 백스페이스가 확정 버퍼를 삭제하지 않게 수정 | 확정 버퍼·문서 유지 회귀 테스트 추가 |
| N-02 | 단독 문자/편집키 및 Shift+문자 거부, 저장된 위험 바인딩 기본값 복구 | 시스템 단축키와 겹치는 조합의 경고 UX는 별도 |
| N-03 | 좌우 상태 분리, 복구 시 재동기화, 반대쪽 Command 보존 | 실제 TCC 회수 및 원격 키보드 입력 확인 |
| N-04 | 기존 전역 recorder 연결, 창/앱 포커스 상실 시 취소 | 실제 설정창에서 현재 전환키 재녹음 확인 |
| N-05 | 영어 입력 완전 pass-through 복원 | 호스트 자체 텍스트 편의에 위임 |
| N-06 | 시스템 편의 캐시 2초 TTL 갱신 | 장시간 상주 상태의 외부 설정 변경 확인 |
| N-07 | 조합·자체 입력 버퍼가 없으면 Space pass-through | Finder Quick Look, 웹 재생/스크롤 확인 |
| N-08 | handle 디버그 로그의 원문 characters 제거 | 기존 로그 자동 삭제는 하지 않음 |
| N-09 | 후속 단계 | 사전 검색을 비동기로 옮기고 입력·포커스·선택 변경 시 요청을 취소하는 세대 모델 필요. 단순 tryLock/빈 결과 반환은 사용자 한자키를 잃으므로 채택하지 않음 |
| N-10 | 영문 버그 고정 테스트 교체, 실제 IMK 대역 재진입/전환 회귀 추가 | Finder 좌표 사설 재구현, defaults 마이그레이션, 버전 파서 경계의 기존 갭은 후속 |
| N-11 | 첫 keyDown에 lightweight 분석을 갱신하고 속성 목록의 의미를 바로잡음 | 실제 비밀번호 필드·stale 전역 플래그 확인 |
| N-12 | dedup에 문자·수정자 추가 | 50ms 시간창 자체는 기존 호스트 호환성 때문에 유지 |
| N-13 | Blink 분류를 직접 삽입 거부에 재사용 | 기본 marked-text 동작 유지 |
| N-14 | 시작 시 HIToolbox snapshot 자동 덮어쓰기 제거 | 명시적 설치/입력 소스 정리 작업의 원자성·성공 검증은 별도 |
| N-15 | tapIsEnabled 실측, 비활성 기존 탭은 start에서 재생성 | OS가 무통지로 탭을 죽이는 경우의 실기기 확인 필요 |

## 원본 저장소 Open Issue / PR 검토

2026-09-09 GitHub REST API의 `issues?state=open`와 두 PR의 files 및 이슈 댓글을 조회했다. **열린 이슈 2건, 열린 PR 2건**이다. 댓글은 #9/#10 모두 유지보수자의 확인 예정 답변이며 추가 재현 정보는 없었다.

| 원본 항목 | 평가와 반영 방향 |
|---|---|
| [#10 영문 전환한뒤 첫글자가 대문자로 타이핑됨](https://github.com/Meapri/PriType-Swift/issues/10) | 이번 영어 완전 pass-through로 해당 PriType 폴백 경로 제거. 빈 필드·문장 경계·따옴표·하이픈·스페이스 회귀 테스트 반영 |
| [#9 ABC 입력소스 끄기 후 다시 살아남](https://github.com/Meapri/PriType-Swift/issues/9) | 비활성 ABC override와 시작 시 plist 덮어쓰기 제거. macOS Caps Lock 설정이나 설치 중복까지 해결됐다고 단정하지 않음. ABC 제거는 TIS 재조회에 따른 성공 검증이 필요한 별도 작업 |
| [PR #11 영문 전환·ABC 재활성, Confluence 목록 분리, 입력 소스 중복](https://github.com/Meapri/PriType-Swift/pull/11) | 실제 diff 검토. 사용자 전환의 selectInputMode 제거 및 이미 활성화된 영어 layout만 override하는 방향을 이번에 재구현. 영문 편의는 PR의 부분 대문자화보다 완전 위임 선택. 보안 입력/캐시/탭 handoff는 현행 수정과 중복 여부 확인. 웹 초성 U+1100 및 첫 marked range의 캐럿 지정은 Confluence 재현 후 별도 적용: 선택 영역 교체·한자·네이티브 조합에 영향을 줄 수 있음. mode ID/레퍼토리/설치 identity 변경은 등록 마이그레이션과 실제 로그아웃 검증 후 별도 적용. PR 통째 cherry-pick은 하지 않음 |
| [PR #12 우측 Command 및 Option 전환 제외 앱 설정 추가](https://github.com/Meapri/PriType-Swift/pull/12) | 원격 Windows App의 키 전달 요구에 유용. 다음 기능 단계에 사용자 관리 제외 목록을 포함. CGEventTap뿐 아니라 IOKit·비동기 callback에도 동일 정책을 적용해야 함. 실제 diff의 focused AX 조회(최대 20ms씩 두 번)는 tap callback에서 수행하므로 재사용 시 포커스 알림 기반 캐시로 옮길 것. 원격 앱/비활성 패널의 포커스 변경 검증 후 도입 |

## 검토 에이전트

요청에 따라 독립 검토 에이전트를 실행했다. 1차에서 이전 컨트롤러의 layout observer 누락, recorder의 타 앱 입력 차단, 오래된 pending 모드 적용을 지적받아 모두 수정했다. 실제 이벤트 진입점을 통한 Command 회복/양쪽 Command 테스트와 모드 세대 테스트를 추가했다. 최종 재검토 결과는 검증 완료 후 아래에 기록한다.

## 검증

- `swift test`: 185 tests / 32 suites 통과.
- `PriTypeVerify`: 기존 조합/전환/설정 검증 실행 완료(출력 내 FAIL 없음). 최종 빌드 재실행 결과는 아래 보충.
- 기본 CommandLineTools의 macOS 27 SDK는 SwiftUIMacros를 찾지 못했다. 설치된 macOS 26.5 SDK를 명시하면 소스 빌드 가능했다. native SwiftPM의 Testing 검색/런타임 경로도 명시해야 이 환경에서 테스트를 실행할 수 있었다.

재현 명령:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/pritype-clang26-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/pritype-swift26-cache \
swift test --disable-sandbox --build-system native \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

설치된 입력기는 아직 교체하지 않았다. 로그아웃/입력 소스 등록/TCC 조작/실제 앱 키 입력은 자동 테스트의 범위 밖이다. 적용 후 우측 Command로 TextEdit↔문제 앱 전환, Finder Space, 녹화 중 타 앱 전환, 비밀번호 필드 복귀, Caps Lock 시스템 모드 전환을 확인해야 한다.
