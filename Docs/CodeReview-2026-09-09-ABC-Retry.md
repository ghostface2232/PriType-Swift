# ABC 재시도 수정 및 수정본 재검토

기준: `3f98e26` 위의 ABC 제거 확인 수정. 기존 커밋의 새 회귀에 한정하지 않고 현행 입력 전환·녹화·대체 처리 경로를 검토했다.

## 수정한 문제

- `.removed`와 `.alreadyAbsent` 모두 `ABCRemovalVerification.confirm`을 통해 실제 TIS의 ABC 부재를 확인해야 성공한다. 설정에 ABC가 없다는 사실만으로 성공하지 않는다.
- 재시도도 메뉴 에이전트 갱신을 요청한다. 최초 요청에서 설정만 반영되고 TIS가 지연된 경우에도 같은 경로를 실행한다.
- TIS 조회 실패 또는 입력 소스 ID 조회 실패를 부재로 오인하지 않는다. 일반 목록 표시 함수의 실패 기본값 `[]`를 제거 성공 근거로 사용하지 않는다.
- 약 3초간 제한된 횟수로 확인한다. 벽시계 변경과 관계없이 대기하며, 설정 화면이 사라지면 작업과 상태 초기화 타이머를 취소한다.
- 테스트는 실제 scratch UserDefaults에서 첫 호출 `.removed` → 다음 호출 `.alreadyAbsent`를 만든 뒤, TIS가 계속 활성 상태면 두 호출 모두 실패하고 실제 부재가 확인된 뒤에만 성공하는 흐름을 실행한다. 시스템 HIToolbox 설정은 변경하지 않는다.

## 추가 발견 — P2 네 건

독립 검토 에이전트가 제시한 경로를 주 검토자가 최신 코드에서 재확인했다. 아래는 이번 ABC 수정으로 발생한 회귀가 아니라 **현재 남아 있는 동작 문제**다. 별도 수정은 수행하지 않았다.

### R1. 조합키 녹화가 단독 수정자로 먼저 확정됨

`RightCommandSuppressor.handleEvent` 녹화 분기는 `flagsChanged`의 modifier DOWN 즉시 `(keyCode, 0)` 콜백을 예약한다. `KeyRecorderRow.receiveBinding`은 이를 저장하고 녹화를 종료한다. 로컬 monitor도 같은 방식이다.

재현 순서: 녹화 시작 → Control 누름 → Space 누름. 통상적인 입력 간격에서 Control+Space 대신 좌측 Control 단독이 저장된다. 단독 modifier는 release 때 확정하고, 그 전에 일반키가 들어오면 조합으로 기록하는 녹화 상태기가 필요하다. 설정의 조합키 및 시스템 단축키 경고 기능을 정상적으로 사용하는 데 영향을 준다.

근거: `Sources/PriTypeCore/RightCommandSuppressor.swift`의 녹화 분기, `SettingsWindowController.swift`의 `startRecording`/`receiveBinding`.

### R2. 서로 다른 수정자를 쓰는 같은 일반키의 한자 바인딩이 무시됨

한자 일반키 처리에 `keyCode != toggleBinding.keyCode` 조건이 있다. 예를 들어 전환을 Control+Space, 한자를 Option+Space로 저장하면 Option+Space는 전환 조건에도 맞지 않고 한자 조건에서도 배제된다. 설정은 전체 바인딩이 달라 충돌로 보지 않는다.

전환 처리에서 이벤트가 실제로 소비되었는지로 분기하고, 키 코드만으로 한자 처리를 차단하지 않아야 한다. 녹화 문제와 독립적이며 기존 저장값/레거시 전환키에서도 성립한다.

근거: `Sources/PriTypeCore/RightCommandSuppressor.swift`의 `// Regular key (non-modifier) as hanja` 분기.

### R3. IOKit 대체 경로가 일반키·조합키 바인딩을 처리하지 못함

`IOKitManager.hidUsage(for:)`는 수정자 키 및 Caps Lock만 매핑하며, 전환 처리에는 `toggleBinding.isModifierOnly` 조건도 있다. UI는 F13이나 Control+Space를 허용한다. F13 사용 중 CGEventTap이 반복 실패해 IOKit으로 인계되면 모니터는 시작돼도 전환키가 동작하지 않는다.

일반키 HID와 modifier 상태를 함께 지원하거나, 미지원 바인딩에서는 탭 복구/명시적 상태 표시가 필요하다. 현재 사용자 기본값인 우측 Command 단독에는 이 제한이 직접 적용되지 않는다.

근거: `Sources/PriTypeCore/IOKitManager.swift`의 `hidUsage(for:)` 및 `handleKeyEvent` 전환 분기.

### R4. 한영/한자 녹화가 동시에 활성 상태로 남음

각 `KeyRecorderRow`는 독립적인 `isRecording`/로컬 monitor를 가지며 시작 시 다른 행을 취소하지 않는다. 전역 tap callback만 마지막 행으로 교체된다.

재현 순서: 한영 녹화 시작 → 한자 녹화 시작 → F13 → F14. F13은 한자에 저장되고, 이전 한영 행의 로컬 녹화가 남아 다음 F14를 한영 바인딩에 저장할 수 있다. 녹화 소유자를 하나로 유지하며 새 세션 시작 시 이전 행을 취소해야 한다. R1 수정과 함께 단일 녹화 상태기로 처리하는 방향을 권장한다.

근거: `Sources/PriTypeCore/SettingsWindowController.swift`의 `KeyRecorderRow.startRecording`/`stopRecording`.

## 검토 및 검증 범위

- 에이전트 1: 전환키·컨트롤러·제외 앱·IOKit·녹화 현행 코드 검토.
- 에이전트 2: ABC 수정본 검토. 기존 false-success 해소 확인, 새 P1/P2 발견 없음.
- 실제 OS 앱 전환, TCC 변경, 입력 소스 제거, 설정창 클릭은 실행하지 않았다. 위 추가 발견은 코드 경로로 확인한 재현 시나리오이며 실제 사용자 환경에서 실행했다고 주장하지 않는다.

검증 결과: `swift test` **247 tests / 39 suites 통과**, `swift run PriTypeVerify` 종료 코드 0 및 FAIL 없음. 기존 계획 문서에 기록한 macOS 26.5 SDK·Testing 경로를 명시해 실행했다. `git diff --check`도 통과했다.
