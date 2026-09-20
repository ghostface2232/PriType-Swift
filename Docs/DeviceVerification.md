# 실기기 검증 (`pritype-device-check`)

`swift test`는 가짜 입력창을 상대한다. 그래서 빠르고, 그래서 답할 수 없는 것이 있다.

- `IOHIDManager`는 HID 드라이버 스택의 하드웨어 리포트만 본다. `CGEventPost`나 `osascript`로 넣은 키는 윈도우 서버 레벨에 삽입되므로 **대체 경로에 아예 도달하지 않는다.** 합성된 형태가 존재하지 않는 코드 경로다.
- HIToolbox는 활성 입력 소스 목록을 프로세스별로 캐시하고, macOS 26 이후로는 갱신하지 않는다. 실행 중인 입력기는 자기가 바꾼 목록을 볼 수 없다.
- 시스템이 만들어 주지 않는 `CGEventTap`은 어떤 대역으로도 흉내 낼 수 없다. 실제 설치본이 대체 경로로 떨어지는 원인이 바로 이것이다.

이 도구는 그 질문들을 실제 머신에 던진다. 테스트 스위트가 답할 수 있는 질문은 여기 두지 않는다 — 중복은 느슨한 쪽이 이기기 마련이고, 이 도구는 매 푸시마다 돌지 않는다.

## 실행

```bash
swift run pritype-device-check
```

사람이 키를 눌러야 하는 검사까지:

```bash
swift run pritype-device-check --interactive
```

`--list`로 검사 목록을, `--only id,id`로 일부만, `--timeout 30`으로 키 입력 대기 시간을 조정한다.

`--only`가 아무 이름도 담고 있지 않으면(`--only ""`, `--only ",,"`, 변수가 빈 `--only "$CHECKS"`) 실행하지 않고 64로 끝난다. 빈 집합은 러너에게 "필터 없음"이므로, 그대로 두면 전체를 돌리고 요청하지 않은 집합에 대해 0을 돌려줄 수 있다.

## 종료 상태

| 값 | 뜻 |
|---|---|
| 0 | 선택된 검사가 전부 실행됐고 전부 통과했다 |
| 1 | 실행된 검사 중 실패가 있다 |
| 2 | 실패는 없지만 **실행되지 못한 검사가 있다** |
| 3 | 검사가 하나도 실행되지 않았다 |
| 64 | 명령줄이 잘못됐다 — 없는 검사 이름, 또는 아무 검사도 가리키지 않는 `--only` |

2가 0과 구분되는 것이 이 도구의 전부다. **실행되지 못한 검사는 통과한 검사가 아니다.** 이 자리에 있던 이전 도구(`PriTypeVerify`)는 `WARNING`을 찍고 성공을 돌려주는 검사를 두 개 가지고 있었고, 그 단언들은 릴리스 빌드에서 사라졌다. 그래서 여기에는 경고 결과가 없고, 단언을 쓰지 않으며, 실제 `UserDefaults`를 쓰지 않고, 머신을 바꾸는 검사는 `--allow-mutation`으로 한 번 더 요청받아야 한다.

## 검사

| id | 묻는 것 |
|---|---|
| `preferences-domain` | 설치본의 설정 도메인(`com.pritype.inputmethod.v2`)을 읽고 있는가 |
| `accessibility` | 손쉬운 사용 권한이 있는가(탭 생성의 전제) |
| `input-monitoring` | 입력 모니터링 권한이 있는가(대체 경로의 전제) |
| `input-source-registered` | PriType이 실제로 입력 소스로 켜져 있는가 |
| `event-tap` | 시스템이 이 프로세스에 세션 탭을 내주고, 전용 런루프가 그것을 처리하는가 |
| `hid-open` | `IOHIDManagerOpen`이 실제 키보드를 여는가 |
| `fresh-process-probe` | 새 프로세스 프로브가 답을 내놓는가 |
| `physical-toggle-tap` | 사람이 누른 전환키가 탭에 도달하는가 (대화형) |
| `physical-toggle-hid` | 사람이 누른 전환키가 대체 경로에 도달하는가 (대화형) |

### `preferences-domain`이 첫 번째인 이유

명령줄 바이너리에는 번들 식별자가 없어서 자기 `UserDefaults.standard`는 PriType이 키를 하나도 쓴 적 없는 빈 도메인이다. 그대로 두면 설정에 의존하는 모든 검사가 **내장 기본값**을 검증하면서 사용자의 설치본을 보고하게 된다 — F13을 전환키로 쓰는 사람에게 "우측 Command를 누르세요"라고 안내하고, 그 사람이 시키는 대로 누르면 통과한다. 그래서 이 질문을 제일 먼저, 소리 내어 한다.

### `hid-open`이 skip으로 나올 때

`IOHIDManagerOpen`이 `kIOReturnExclusiveAccess`(-536870203)를 돌려주면 누군가 이미 키보드를 **seize**한 것이다. 권한 부족은 `kIOReturnNotPermitted`(-536870174)로 따로 구분된다.

**PriTypeV2는 대개 범인이 아니다.** PriType은 `kIOHIDOptionsTypeNone`으로, 즉 비배타로 연다 — 비배타끼리는 공존한다. 게다가 `IOKitManager`는 CGEventTap이 실패했을 때만 도는 대체 경로라, 평소 PriType은 HID 매니저를 아예 열지 않는다. 실제로 이 Mac에서 PriTypeV2를 종료하고 `pgrep`으로 확인한 뒤에도 같은 오류가 났다.

장치를 seize하는 쪽은 **키 리맵퍼**다. Karabiner-Elements가 대표적이고, 그게 그 프로그램의 동작 방식이다. skip 메시지는 알려진 후보 중 지금 실제로 도는 것들을 나열한다 — IOKit은 누가 쥐고 있는지 알려주지 않으므로, 그 목록은 단정이 아니라 찾아볼 곳이다.

이 검사와 `physical-toggle-hid`를 실제로 돌리려면 그 프로그램을 멈춰야 한다. Karabiner는 `SMAppService`로 권한 데몬을 등록하므로 `launchctl`로 내려가지 않는다 — Karabiner-Elements 설정의 Misc에서 종료하거나, 시스템 설정 > 일반 > 로그인 항목의 백그라운드 항목에서 끈다.

### 합성 입력으로는 통과시킬 수 없다

탭은 `CGEventPost`로 넣은 키도 본다. 이것은 안 보이는 것보다 나쁘다 — 스크립트로 돌린 검증이 "전환키가 동작한다"고 보고할 수 있기 때문이다. 그래서 `RightCommandSuppressor`는 처리한 토글의 이벤트 소스 pid를 기록하고, `physical-toggle-tap`은 프로세스가 넣은 토글을 실패로 처리한다. 하드웨어가 만든 키는 pid 0으로 온다. `physical-toggle-hid`는 그런 방어가 필요 없다 — HID 스택에는 합성 이벤트가 들어오지 않는다.

## 환경 주의

- 키 리맵퍼(Karabiner-Elements 등)가 같은 키를 먼저 소비하면 대화형 검사가 실패한다. 테스트 중에는 꺼 둔다.
- 내장 키보드에는 F13이 없다. 대체 키: `Control+Space`(조합), `Fn+F5`(일반키), 우측 Option(수정키).
- 디버그 로그는 `~/Library/Logs/PriType/pritype_debug.log`에 남고 릴리스 빌드에서는 남지 않는다. 사용자가 친 내용은 `logSensitive`를 거쳐 `[REDACTED]`로 기록된다.
