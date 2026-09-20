PriType 코드 리뷰 · 2026-09-20 · 기준 커밋 `86e6fd3`

현재 구조에는 유지할 가치가 큰 선택들이 있다. 세션과 전달 어댑터를 분리했고, 한자 사전은 정렬된 바이너리와 메모리 매핑으로 단순하게 만들었으며, 실제 입력 컨트롤러를 구동하는 테스트 하니스가 있다. 다음 작업의 우선순위는 입력의 정확성이다. 기존 테스트 406개는 모두 통과하지만, 이번에 추가한 경계 조건 재현 6개 중 5개가 실패했다. 전면 재작성보다 이벤트 순서, 편집 대상의 유효성, 조합 상태의 수명을 명시하는 작은 변경들이 효과적이다.

리뷰 범위는 입력 컨트롤러·세션·조합기·전달 어댑터, CGEventTap/IOKit 전환 경로, 한자 사전과 후보창, 커서 탐색, 설정 및 업데이트 수명 관리, 테스트·벤치마크·빌드/배포 스크립트다. 프로덕션 코드는 수정하지 않았다. 설치·서명·공증·배포는 실행하지 않았다. 실제 앱에서의 발생 빈도와 장시간 메모리 누수는 이번 하니스 검증만으로 확정하지 않는다.

**검증 결과와 근거.** Apple M5, RAM 24GiB, macOS 27.0(26A428), Apple Swift 6.4에서 검증했다. 최초 샌드박스 실행에서는 화면 정보를 얻지 못해 커서 테스트 3개에 assertion 4개가 실패했으나, macOS 접근 제한을 해제한 실행에서는 **406 tests / 57 suites 전부 통과**했다. `swiftlint lint --strict --quiet --no-cache`도 진단 없이 종료했다. 아래 추가 재현의 실패는 같은 접근 제한 없는 환경에서도 확인했다.

| 근거 | 파일 |
| --- | --- |
| 실행 환경·기존 테스트·린트 요약 | [verification.txt](/Users/baemingwan/Documents/AI/PriType-Swift/Docs/ReviewEvidence-2026-09-20/verification.txt) |
| 추가 재현 코드 | [ReviewReproductionProbes.swift.txt](/Users/baemingwan/Documents/AI/PriType-Swift/Docs/ReviewEvidence-2026-09-20/ReviewReproductionProbes.swift.txt) |
| 추가 재현 출력 | [reproduction.log](/Users/baemingwan/Documents/AI/PriType-Swift/Docs/ReviewEvidence-2026-09-20/reproduction.log) |
| Release 측정 원본 | [1회](/Users/baemingwan/Documents/AI/PriType-Swift/Docs/ReviewEvidence-2026-09-20/benchmark.log), [2회](/Users/baemingwan/Documents/AI/PriType-Swift/Docs/ReviewEvidence-2026-09-20/benchmark-run2.log), [3회](/Users/baemingwan/Documents/AI/PriType-Swift/Docs/ReviewEvidence-2026-09-20/benchmark-run3.log) |

추가 재현 코드는 일시적으로 테스트 타깃에 넣어 실행한 뒤 제거했다. 보관된 `.swift.txt`는 자동 테스트에 포함되지 않는다. 재실행하려면 이를 `Tests/PriTypeCoreTests/ReviewReproductionProbes.swift`로 복사하고 `swift test --filter ReviewReproductionProbes`를 실행한다. 현재 코드에서는 기대 동작을 검증하는 다섯 테스트가 실패하는 것이 재현 결과다. 실행 뒤 복사한 파일을 제거하면 기존 테스트 구성으로 돌아간다. 설정 변경을 쓰는 재현은 기존 값을 복원한다. 시스템 Caps Lock 전환이 꺼져 있고 두 번 스페이스 치환이 켜진 환경에서 실행했다.

**1. [P1] 50ms 이내의 정상적인 같은 키 입력이 제거된다 — 재현 확인.**

위치: [DirectInsertionPlanner.swift:28](/Users/baemingwan/Documents/AI/PriType-Swift/Sources/PriTypeCore/DirectInsertionPlanner.swift:28), 호출부 [PriTypeInputController.swift:449](/Users/baemingwan/Documents/AI/PriType-Swift/Sources/PriTypeCore/PriTypeInputController.swift:449).

`KeyEventDedup.isDuplicate`는 시각이 서로 달라도 키 코드·문자·수정키가 같고 간격이 0–50ms이면 같은 물리 이벤트로 간주한다. 이 조건은 별개의 빠른 입력과 중복 전달을 구분하지 못한다. 반복 입력 플래그가 없는 30ms 간격의 `r`, `r`를 보내고 확정하면 기대한 `ㄱㄱ` 대신 `ㄱ`만 남는다. 같은 규칙이 모든 앱과 전달 모드에 적용되고, 조합 중 Backspace도 이전 처리 결과가 `true`이면 두 번째 삭제가 사라진다. 중복으로 판정한 이벤트도 `lastKeyDown`을 갱신하므로 50ms 미만으로 이어지는 동일 키 열 전체가 첫 입력 하나로 축소될 수 있다.

주석의 “사람은 50ms 안에 같은 키를 누를 수 없다”는 입력 무결성의 근거가 될 수 없다. 합법적인 합성 입력이나 서로 다른 장치의 입력도 지원 범위에서 구분해야 한다. Apple의 `NSEvent.timestamp`는 부팅 이후 이벤트 발생 시각이지, 일정 시간 안의 이벤트가 동일하다는 보증이 아니다. [Apple 문서](https://developer.apple.com/documentation/appkit/nsevent/timestamp).

수정 방향: 먼저 실제 중복 전달 표본에서 보존되는 이벤트 식별 정보를 확인한다. 같은 timestamp와 키 정보의 정확한 재전달만 제거하는 방식을 우선 검토하고, timestamp를 새로 만드는 호스트라면 해당 호스트에 한정된 근거가 필요하다. 시간 창만 좁히는 처방은 오탐의 경계를 옮길 뿐이다. 서로 다른 timestamp의 연속 입력, 정확한 재전달, auto-repeat, 두 번 스페이스, 조합 Backspace를 함께 검증한다. 기존 하니스가 `keyInterval = 0.08`로 이 규칙을 피해 가고 있어 정상 입력 손실이 기존 테스트에서 드러나지 않았다.

**2. [P1] 전환 큐가 먼저 실행되면 과거 키가 새 언어로 처리된다 — 재현 확인.**

위치: [InputModeCoordinator.swift:82](/Users/baemingwan/Documents/AI/PriType-Swift/Sources/PriTypeCore/InputModeCoordinator.swift:82).

타임스탬프 필터는 액션이 아직 대기열에 있을 때만 작동한다. 이벤트 탭이 등록한 `DispatchQueue.main.async`는 시각 제한 없이 `applyPendingKeyActions()`를 호출한다. 한글 모드에서 먼저 발생한 `r`의 IMK 도착을 늦추고, 이후 전환키의 실제 main-queue 블록을 먼저 실행하면, 나중에 도착한 `r`은 `ㄱ`이 아닌 영문 `r`이 된다. 추가 재현은 큐 drain 함수를 수동으로 호출하는 대신 실제 예약 블록이 실행되도록 기다려 확인했다.

현재 구현은 “전환 이후 키가 전환을 추월하는 경우”를 방지하지만 반대 순서까지 보장하지 않는다. IOKit 경로도 원래 HID 이벤트 시각을 버리고 main queue에서 콜백을 나중에 실행하므로 같은 순서 계약을 제공하지 못한다. [IOKitManager.swift:224](/Users/baemingwan/Documents/AI/PriType-Swift/Sources/PriTypeCore/IOKitManager.swift:224).

수정 방향: 전환과 입력의 발생 순서 및 이미 처리된 지점을 구분해야 한다. 모든 키의 도착 기록이 필요한지, 제한된 이벤트/모드 이력으로 해결 가능한지 작은 실험으로 결정한다. 늦게 도착한 키의 모드만 바꾸어 처리하는 것으로는 충분하지 않다. 이전 조합의 flush까지 그 키와 올바른 순서로 실행돼야 한다. 단순 `asyncAfter`, 큐 정렬, debounce 추가로 완전한 순서를 보장한다고 선언하지 않는다. IMK로 전달되지 않는 키가 있는 호스트에서도 전환이 영구 대기하지 않는 조건을 함께 설계해야 한다.

완료 기준은 키→전환→키, 전환→키, 연속 전환, 한자키→숫자키, 포커스 이동을 각각 양쪽 도착 순서로 재생해 텍스트·모드·조합 소유자가 일치하는 것이다. 실제 호스트에서 이 순서가 발생하는 빈도는 별도 측정 대상이다.

**3. [P1] 두 번 스페이스 치환이 이동한 커서 앞의 기존 글자를 지운다 — 재현 확인.**

위치: [TextConvenienceHandler.swift:59](/Users/baemingwan/Documents/AI/PriType-Swift/Sources/PriTypeCore/TextConvenienceHandler.swift:59), [TextDelivery.swift:218](/Users/baemingwan/Documents/AI/PriType-Swift/Sources/PriTypeCore/TextDelivery.swift:218).

치환 조건은 `localTextBuffer`가 공백으로 끝나는지만 확인한다. 어댑터는 현재 커서 앞 한 UTF-16 단위를 그대로 교체한다. `가␠`를 입력한 뒤 조합이 없는 상태에서 커서를 `가` 바로 뒤로 옮기고 0.45초 안에 스페이스를 누르면, `가␠␠`가 되어야 할 문서가 `.␠␠`가 된다. 기존 `가`가 삭제된 것이다. 조합이 없을 때의 클릭은 IMK에 commit callback을 보내지 않을 수 있으므로 `commitComposition`에서 버퍼를 비우는 것만으로 막을 수 없다.

수정 방향: 자동 치환이 편집하려는 공백의 범위와 세션을 기억하고, collapsed selection·커서 위치·해당 범위의 실제 공백을 치환 직전에 확인한다. 실시간 읽기가 불가능하면 새 공백을 정상 입력한다. 모든 키마다 문서를 읽을 필요는 없다. 실제 두 번째 스페이스 후보일 때만 검증한다. 직접 입력 어댑터의 기존 범위 검증 방식과 원칙을 맞추되, 필요 이상의 범용 편집 프레임워크는 만들지 않는다.

**4. [P2] 치환할 수 없는 클라이언트에서 두 번째 스페이스가 사라진다 — 재현 확인.**

위치: [TextConvenienceHandler.swift:65](/Users/baemingwan/Documents/AI/PriType-Swift/Sources/PriTypeCore/TextConvenienceHandler.swift:65).

`replaceTextBeforeCursor`는 `Void`를 반환한다. 선택 영역이 `NSNotFound`이거나 너무 작은 경우 아무 작업 없이 반환하지만, 호출자는 버퍼를 `. `로 갱신하고 `.convertedToPeriod`를 반환한다. 조합기는 이 반환값을 근거로 스페이스 이벤트를 소비한다. 재현에서는 `NSNotFound`인 클라이언트에서 치환이 실행되지 않았는데도 `.convertedToPeriod`가 반환됐다. 범위를 제공하지 않는 호스트에서는 사용자 입력이 조용히 유실된다.

수정 방향: 어댑터가 최소한 `.issued` / `.unavailable`을 구분해 반환하도록 한다. `.unavailable`이면 스페이스를 입력하고 버퍼를 실제 출력에 맞춘다. IMK의 `insertText` 자체는 성공 응답을 주지 않으므로 이 결과를 “호스트가 적용했음”이라고 과장해서는 안 된다. 3번의 대상 검증과 이 실패 분기를 함께 구현하면 같은 기능의 데이터 손상과 입력 유실을 동시에 줄인다.

**5. [P2] 조합 중 전달 어댑터를 교체하면 이미 입력한 음절이 중복된다 — 재현 확인.**

위치: [InputSession.swift:92](/Users/baemingwan/Documents/AI/PriType-Swift/Sources/PriTypeCore/InputSession.swift:92).

`ensureAdapterMatchesPolicy()`는 기존 어댑터의 상태를 마무리하지 않고 새 어댑터로 교체한다. 직접 입력 모드에서는 조합 중 `가`가 이미 문서에 실제 텍스트로 존재한다. 이때 설정을 끄고 `ㅗ` 키를 처리하면 새 marked-text 어댑터가 엔진의 `가`를 다시 삽입하여 기대한 `가ㅗ` 대신 `가가ㅗ`가 된다. UI를 열면서 포커스가 이동하는 경로에서는 조합이 먼저 끝날 수 있지만, 외부 설정 변경과 코드가 명시적으로 지원하는 세션 중 정책 변경 경로에는 이 보장이 없다.

수정 방향: 어댑터 교체를 조합 경계로 정의한다. 기존 어댑터가 `directLive`인지 `markedFallback`인지에 따라 기존 세션의 finalize를 먼저 수행하고, 엔진과 추적 상태가 빈 상태에서 새 어댑터를 설치한다. 상태를 보존하는 마이그레이션은 복잡도가 더 크므로 실제 UX 요구가 있을 때만 선택한다. direct→marked, marked→direct, markedFallback→다른 정책, Finder의 lightweight context 갱신을 검증한다.

**6. [P2, Debug 한정] 민감 입력 마스킹을 우회하는 한자 로그가 있다 — 정적 확인.**

위치: [HangulComposer.swift:774](/Users/baemingwan/Documents/AI/PriType-Swift/Sources/PriTypeCore/HangulComposer.swift:774), [HangulComposer.swift:852](/Users/baemingwan/Documents/AI/PriType-Swift/Sources/PriTypeCore/HangulComposer.swift:852).

`logSensitive`는 기본 Debug 빌드에서도 입력을 숨기도록 설계됐지만, 한자 후보를 찾았을 때의 `searchKey`와 선택한 `entry.hanja`/`entry.meaning`은 일반 `DebugLogger.log`로 기록된다. 마스킹 옵션을 해제하지 않은 Debug 빌드에도 검색한 단어와 선택 결과가 남는다. Release에서는 로깅 함수가 비활성화되어 이 지적의 영향 범위가 다르다.

수정 방향: 입력 유래 내용은 모두 `logSensitive`로 보내고, 기본 진단에는 길이·후보 수·상태·시간만 남긴다. 로그 문구에 테스트용 비밀 표식을 넣어 기본 Debug 출력에 존재하지 않는지 확인하는 한 개의 통합 검증이 문자열별 테스트보다 유용하다.

**낮은 우선순위의 확인 사항.** 다음은 위의 재현된 입력 결함과 구분한다.

- [DebugLogger.swift:139](/Users/baemingwan/Documents/AI/PriType-Swift/Sources/PriTypeCore/DebugLogger.swift:139): `cachedHandle != nil`이면 파일 크기를 확인하지 않아 5MiB 회전 기준이 지속 실행 중에는 적용되지 않는다. 오래 실행하는 Debug 입력기는 단일 로그가 계속 커질 수 있다. 큐에서 바이트 수를 관리하고 임계값에서 닫기→회전→재열기를 수행하면 매 줄 filesystem 조회도 없앨 수 있다. 수일 실행 재현은 하지 않았다.
- [PriTypeBenchmark/main.swift:401](/Users/baemingwan/Documents/AI/PriType-Swift/Sources/PriTypeBenchmark/main.swift:401): 실패를 출력해도 비정상 종료 코드를 반환하지 않는다. 이후 CI gate로 활용하려면 결과를 exit status에 연결한다. 현재 CI는 이 프로그램을 실행하지 않으므로 현재 CI 실패 은폐로 확대 해석하지 않는다.
- [HanjaManager.swift:98](/Users/baemingwan/Documents/AI/PriType-Swift/Sources/PriTypeCore/HanjaManager.swift:98): `search`는 다른 스레드의 로딩을 기다리지는 않지만, 아직 `.unloaded`이면 검색 스레드에서 직접 `loader()`를 실행한다. preload 작업이 아직 시작하지 못한 첫 한자키에서는 main thread의 파일 접근이 가능하다. 작은 사전의 실제 비용을 측정한 뒤 ready-only 조회와 비동기 로딩의 분리를 결정한다.
- `SettingsWindowController`의 키 녹음 소유권·취소 및 지연 작업 정리는 테스트로 뒷받침된다. 1,116줄이라는 이유만으로 새 MVVM 계층을 추가할 필요는 없다. 화면별 파일 분리는 탐색성을 개선하지만 성능 개선과 구분한다.
- 입력기 설치 스크립트는 기존 설치 삭제와 프로세스 종료를 포함한다. 리뷰 과정에서는 실행하지 않았다. 패키징·업데이트 중단 시 복구와 최소 지원 macOS에서의 설치 검증은 별도 release validation으로 남는다.

**현재 성능에서 읽을 수 있는 것.** 같은 Release 바이너리를 새 프로세스로 세 번 실행했고 모두 `ALL TESTS PASSED`였다. 메모리 함수는 `resident_size / 1024 / 1024`를 계산하므로 로그의 MB는 엄밀히 MiB다.

| 측정 항목 | 1회 | 2회 | 3회 |
| --- | ---: | ---: | ---: |
| 한자 사전 첫 로드 | 4.50ms | 0.76ms | 0.84ms |
| `가` 검색, 10,000회 평균 | 5.00µs | 4.08µs | 4.07µs |
| 한글 5,140키 p50 / p99 | 4.6 / 27.7µs | 5.5 / 47.7µs | 5.4 / 34.2µs |
| 영문 5,140키 p50 / p99 | 0.6 / 1.1µs | 0.7 / 1.0µs | 0.6 / 2.2µs |
| Backspace 600키 p99 | 6.1µs | 7.4µs | 7.1µs |
| 전환 직후 첫 키 200개 p99 | 29.2µs | 28.6µs | 53.7µs |
| 벤치마크 종료 시 RSS | 24.6MiB | 24.6MiB | 24.6MiB |

첫 실행의 사전 매핑·첫 조회에는 파일 페이지와 시스템 초기화 영향이 있다. 새 프로세스라고 디스크까지 cold 상태인 것은 아니다. 세 번은 탐색용 표본이며 엄밀한 성능 회귀 판정의 통계적 근거로 삼지 않는다. `BENCHMARK.md`의 과거 수치와 차이가 있으나, 동일 조건의 과거 커밋 A/B 실행을 하지 않았으므로 회귀 원인이나 배율을 확정하지 않는다.

하니스의 키 지연은 `handle()` 진입부터 FakeTextClient 처리 완료까지다. 이벤트 탭 대기, 호스트→IMK 전달, 실제 텍스트 API의 IPC, 화면 표시 시간은 포함하지 않는다. 따라서 “사용자 타이핑 지연이 5µs”라는 결론은 성립하지 않는다. 메모리 역시 실제 상주 앱의 footprint가 아니라 벤치마크 프로세스의 RSS이며 하니스, 문자열 기록, 표본 배열을 포함한다. 장시간 누수의 증거는 이번 측정에서 얻지 못했다.

**속도 개선은 긴 동기 대기를 먼저 측정하는 순서로 진행한다.**

| 순서 | 변경 후보와 이유 | 검증 기준 |
| --- | --- | --- |
| 1 | 진단 빌드에서 이벤트 접수→큐 대기→세션 준비→조합→클라이언트 쓰기를 별도 구간으로 측정. 문자 내용은 기록하지 않는다 | TextEdit·Terminal·Chrome·Electron에서 p50/p95/p99/max, IPC 횟수, main thread blocked time을 분리 |
| 2 | `CursorRectResolver`의 동기 AX fallback에 호출별 제한 외 전체 시간 예산을 설계 | 응답하지 않는 호스트에서 한자 후보 표시가 입력기 main thread를 초 단위로 점유하지 않는지 검증 |
| 3 | 이벤트 탭이 읽는 Caps Lock preference 갱신을 callback 밖에서 수행하는 방안 평가 | `PolledPreference.value`의 약 1초마다 발생하는 실제 preference read가 callback p99에 보이는지 먼저 확인 |
| 4 | 전환 후 main queue에서 수행하는 TIS 보고를 관측하고 불필요한 연속 보고 병합 여부 검토 | 보고 지연과 다음 키 지연 분리. 실제 시스템 선택·echo 필터·연속 전환 정확성 유지 |
| 5 | 첫 한자 조회·자모 JSON 로딩, 결과 문자열 생성을 profile | 첫 조회 p99에 유의미한 경우에만 preload 확대 또는 페이지 단위 decode 채택 |
| 6 | 한글 변환의 임시 배열·문자열과 음절 키 재생 비용 줄이기 | Allocations/Time Profiler에서 지배 비용일 때만 변경; 동일 문장·Backspace 의미 보존 |

특히 [CursorRectResolver.swift:143](/Users/baemingwan/Documents/AI/PriType-Swift/Sources/PriTypeCore/CursorRectResolver.swift:143)는 AX 호출당 0.5초의 timeout을 사용하며 여러 번의 동기 호출을 이어간다. 느린 호스트에서 초 단위 대기가 가능한 구조다. 이 최악 지연은 실제 느린 앱으로 재현하지 않았으므로 측정 후보로 분류한다. 별도 작업으로 옮길 경우에도 NSView/NSWindow 갱신은 main에서 수행하고, 늦은 좌표 결과는 세션 세대가 바뀌었으면 버려야 한다. 시스템 전체 AX timeout 변경의 영향도 확인한다.

계측은 문자열 로그를 늘리기보다 `OSSignposter` 구간을 사용하는 편이 적합하다. Apple은 signpost 구간을 Instruments 시간축에서 분석하도록 제공하며, responsiveness 문서는 main thread의 동기 작업을 우선 조사하도록 안내한다. [OSSignposter](https://developer.apple.com/documentation/os/ossignposter), [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness).

현재 한글 처리 비용만 보면 임시 배열 하나를 없애 얻는 절대 이득은 작을 가능성이 높다. 다만 [CompositionHelpers.swift:13](/Users/baemingwan/Documents/AI/PriType-Swift/Sources/PriTypeCore/CompositionHelpers.swift:13)의 연속 `compactMap`/`map`과 `HangulComposer`의 최대 5키 재생은 측정하기 좋은 후보다. 한 스레드가 소유하는 엔진에 매 호출마다 lock을 거는 wrapper를 사용하는 것도 검토할 수 있으나, 소유권을 먼저 강제한 뒤에만 lock 제거를 고려한다. 단순히 `@unchecked Sendable`을 더 붙이거나 lock을 제거해 속도를 얻는 방식은 권하지 않는다.

**메모리는 상주 비용과 관측 도구의 비용을 구분한다.**

현재 `hanja.dat` 매핑 방식은 유지한다. 222,709개 키의 사전을 런타임 객체 그래프로 파싱하지 않고, 정렬 오프셋 표와 이진 탐색으로 처리하는 선택이 이 코드베이스에서 가장 좋은 성능·단순성 균형이다. 읽기 전용 페이지는 운영체제의 페이지 캐시를 활용할 수 있다. 무제한 결과 캐시나 trie 재도입은 현재 수치로 정당화되지 않는다. [Apple의 파일 매핑 설명](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemAdvancedPT/MappingFilesIntoMemory/MappingFilesIntoMemory.html).

실제 프로세스에서 다음 단계별로 RSS와 `phys_footprint`, dirty/clean 영역, 살아 있는 객체 수를 함께 측정한다: 실행 직후 → 사전 준비 → 여러 앱 100회 전환 → 한자 후보 100회 표시/닫기 → 한자 기능 끄기 → idle. 표시된 파일 크기나 한 번의 RSS 감소만으로 누수 여부를 판단하지 않는다. macOS의 `footprint`는 dirty 및 공유 메모리를 구분하는 도구다. 로컬 Apple 매뉴얼: `/usr/share/man/man1/footprint.1`.

후보창은 이미 숨길 때 후보 배열과 SwiftUI 콘텐츠를 해제하도록 구현돼 있다. 여기에는 일괄적인 “view 재사용 캐시”를 더하기보다 실제 반복 실행의 잔존 객체를 본다. 공유 조합기의 `lastDelegate`, 각 컨트롤러의 보존 세션, observer, NSPanel/NSHostingView가 의도한 범위만큼만 살아 있는지 Memory Graph에서 확인한다. `lastDelegate`가 한 클라이언트를 보존하는 것 자체를 무제한 누수라고 판정하지 않는다.

**선호하는 구조는 더 적은 규칙을 더 강하게 지키는 구조다.**

현재 `InputSession`을 중심에 두고 다음 네 가지 계약을 명시하는 것이 작은 변경으로 여러 문제를 해결한다.

1. 엔진과 현재 편집의 소유자는 하나다. 같은 앱이라는 사실은 같은 필드·문서라는 증거가 아니다. 필드가 바뀌면 세션 세대를 증가시키고 지연 콜백과 위치 기반 편집이 이를 검증한다.
2. 위치 기반 치환은 세션·범위·예상 문자열을 근거로 수행한다. 이를 증명할 수 없는 호스트에서는 원래 입력을 보존한다. 캐시는 읽기 최적화일 수 있지만 쓰기 권한의 유일한 근거가 되어서는 안 된다.
3. 전달 방식이 바뀌면 기존 방식으로 조합을 마친다. `directLive`, `markedFallback`, `idle`의 의미를 수명 경계까지 일관되게 유지한다.
4. 발생 시각, 큐 도착 시각, 문서 적용 시각을 구분한다. main queue의 직렬 실행은 서로 다른 생산자의 발생 순서까지 보장하지 않는다.

이를 위해 거대한 이벤트 버스나 새로운 범용 상태 관리 계층이 필요한 것은 아니다. 현재의 `InputSession`·작은 정책 함수·세 종류 어댑터를 유지하고, 자동 치환의 결과 타입과 세션 세대, 이벤트 순서 계약을 보강한다. `HangulComposer`의 한자 UI·전역 컨트롤러 접근은 기능을 수정할 때 작은 협력 객체로 옮겨 순수 조합 로직과 분리할 수 있다. 앱별 호환성 예외는 정책 파일에서 근거·회귀 사례와 함께 유지한다.

`@unchecked Sendable`/`nonisolated(unsafe)`가 존재한다는 이유만으로 data race를 단정하지는 않는다. 다만 IMK의 Objective-C 경계와 달리 내부 세션·후보 UI·상태 소유자는 main actor로 표현할 여지가 있다. 프레임워크 경계에서 실행 문맥을 확인하고 내부의 보장을 강화하면 여러 곳의 주석에만 의존하는 부담을 줄일 수 있다.

**실행 계획과 완료 기준.** 아래 단위로 나누면 각각 검토와 되돌리기가 쉽다.

| 단계 | 작업 | 완료 기준 |
| --- | --- | --- |
| A | 1번 중복 판정, 3·4번 두 번 스페이스 처리 | 이번 기대 동작 재현 통과. 빠른 입력·정확한 중복 전달·선택 영역·읽기 불가능한 호스트에서 키 유실 없음 |
| B | 5번 어댑터 교체를 조합 경계로 통일 | 각 전달 상태와 정책 전환 조합에서 중복/잔류 조합 없음 |
| C | 2번의 이벤트 순서 설계 실험 및 구현 | 양쪽 도착 순서와 IMK에 오지 않는 키를 포함한 테스트, 실제 호스트 추적에서 일치 |
| D | 로그 마스킹·회전, 벤치마크 실패 종료 코드 | 기본 Debug에 표식 문자열 없음, 장기 로그 크기 상한, 실패 시 CI가 감지 가능 |
| E | signpost/메모리 기준선 구축 후 가장 큰 대기 하나 개선 | 같은 머신·빌드·시나리오에서 반복 A/B, 정확성 검증 통과, 개선이 노이즈보다 큼 |

테스트 확장은 private flag별 assertion보다 상태 전이의 조합을 재생하는 방식이 좋다. `key / duplicate / toggle / focus / policy change / click / candidate select`를 짧은 시퀀스로 생성하고, 늦은 응답·변경 없는 응답·nil 범위·NFD·긴 선택 영역을 반환하는 fake client와 결합한다. “소비한 키에는 그에 대응하는 결과가 있다”, “다른 필드의 문서를 편집하지 않는다”, “확정은 반복 호출해도 중복되지 않는다”를 검사한다. 이번 `rkrkr`→Backspace 반례 탐색은 통과했으므로 키 재생 자체의 음절 중복 결함으로 보고하지 않았다.

최종적으로 macOS 14와 현재 macOS, native·Terminal·Chromium/Electron에서 대표 시나리오를 확인한다. 기존 406개 테스트와 lint는 기반이고, 실제 호스트에서의 IPC·포커스·조합 callback 계약은 별도의 검증층이다. 가장 먼저 투자할 곳은 더 많은 앱 이름을 예외 목록에 넣는 작업이 아니라, 이미 존재하는 편집과 이벤트 상태의 의미를 일관되게 만드는 작업이다.
