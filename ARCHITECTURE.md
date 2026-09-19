# 아키텍처

이 문서는 현재 코드가 실제로 하는 일을 설명한다. 파일 이름은 `Sources/PriTypeCore/` 기준이다. 설계 결정의 배경과 폐기된 대안은 `Docs/`의 계획·리뷰 문서에 남아 있으며, 날짜가 붙은 기록이므로 현재 동작과 다를 수 있다.

## 개요

PriType은 InputMethodKit(IMK) 입력기 하나로 한글과 영문을 모두 처리한다. macOS에는 입력 소스 하나(`com.pritype.inputmethod.v2`)와 그 아래 입력 모드 두 개(한국어, 영문)로 등록된다. 한글은 libhangul-swift로 조합하고, 영문 모드에서는 키를 조합 없이 앱에 그대로 넘긴다. 한/영 전환은 macOS 입력 소스 전환이 아니라 PriType 내부의 모드 전환이며, 전환키는 전역 이벤트 탭으로 감지한다.

```
앱 (IMK 클라이언트)
  텍스트 입력창  ◄── insertText / setMarkedText (IMKTextInput)
        ▲
PriTypeV2.app
  IMKServer ──► PriTypeInputController        클라이언트마다 하나
                  │  activateServer / handle / deactivateServer / setValue
                  ▼
                InputSession                   클라이언트, 컨텍스트, 전달 어댑터, 조합 종료 단일 경로
                  │
                  ▼
                HangulComposer                 공유 하나, libhangul-swift로 조합
                  ├─ HanjaManager / HanjaDictionary   메모리 매핑 한자 사전
                  └─ HanjaCandidateWindow              후보창 (NSPanel)

  이벤트 탭 스레드: RightCommandSuppressor (CGEventTap)  ─┐
  메인 (대체 경로): IOKitManager (IOHIDManager)          ─┴─► InputModeCoordinator ──► 메인에서 키 순서대로 실행
```

## 등록 정보 (Info.plist)

- 번들 ID `com.pritype.inputmethod.v2`, 실행 파일 `PriTypeV2`, `LSUIElement`.
- `InputMethodConnectionName` = `PriType_InputString_v2`, `InputMethodServerControllerClass` = `PriTypeInputController`.
- 입력 모드(`ComponentInputModeDict`)
  - `com.pritype.inputmethod.v2`: 한국어(`smKorean`), 아이콘 `input-ko.tiff`.
  - `com.pritype.inputmethod.v2.english`: 영문(`smRoman`), 아이콘 `input-en.tiff`.
  - 메뉴 막대의 입력 소스 아이콘이 현재 모드를 보여 준다. 별도의 메뉴 막대 표시기는 없다.
- `TICapsLockLanguageSwitchCapable` = true. macOS의 Caps Lock 입력 소스 전환이 두 모드 사이를 오갈 수 있다.
- 최상위나 모드별 `TISInputSourceID`는 두지 않는다. `RegistrationContractTests`가 이 계약을 지킨다.

## 시작 순서 (`Sources/PriType/main.swift`)

1. `--abc-layout-status` 인자로 실행되면 ABC 자판 상태만 출력하고 종료한다(`ABCLayoutStatusProbe`, 아래 "입력 소스 관리" 참고).
2. `IMKServer`를 만든다.
3. 저장된 키 바인딩을 이관·보정한다(`ConfigurationManager.migrateKeyBindingsIfNeeded`).
4. 앞에 있는 앱을 추적해 전환 제외 앱을 판정할 준비를 한다(`ToggleExclusionPolicy.start`).
5. 키 모니터를 시작한다(`KeyMonitors.start`, 설정 창의 권한 버튼도 같은 함수를 부른다).
   - 손쉬운 사용 권한이 없으면 시스템 요청 창을 띄우고, 허용될 때까지 1초마다 확인한 뒤 다시 시작한다.
   - `RightCommandSuppressor`(CGEventTap)를 시작한다. 실패하거나 나중에 탭이 반복해서 꺼지면 `IOKitManager`로 넘긴다. IOKit 경로는 입력 모니터링 권한을 확인하고, 없으면 요청한 뒤 허용될 때까지 2초마다 확인한다.
6. 한자 변환이 켜져 있으면 백그라운드에서 한자 사전을 매핑한다.
7. 업데이트 알림을 준비하고, 자동 확인이 켜져 있으면 백그라운드에서 새 버전을 확인한다.

## 키 입력 경로

```
keyDown ──► PriTypeInputController.handle(event, client)
   1. claimActiveController        공유 조합기의 주인을 이 컨트롤러로 바꾸고(이전 주인의 조합 확정, 한자 후보창 닫기), 보류된 시스템 모드를 적용
   2. ensureSession(client)        같은 클라이언트면 세션 재사용, 필요하면 컨텍스트 재분석, 다르면 새 세션
   3. applyPendingKeyActions       이 키보다 먼저 눌린 전환·한자 동작만 먼저 실행
   4. 중복 keyDown 억제             같은 물리 키를 두 번 보내는 앱(KakaoTalk 등): 두 번째는 첫 결과를 재사용
   5. markKeystroke(bundleId)      앱이 바뀌었으면 입력 버퍼를 비우고, 한자 검색이 볼 앱을 기록
   6. Secure Input 게이트           비밀번호 입력 등: 조합을 버리고 키를 그대로 통과
   7. ensureAdapterMatchesPolicy   전달 방식이 바뀌었으면(실험 설정 변경 등) 어댑터 교체
   8. prepareForInput              직접 삽입 모드: 이전 글자가 아직 제자리인지 확인
   9. HangulComposer.handle(event, delegate: session.adapter)
```

`HangulComposer.handle`은 다음 순서로 판단한다.

- 방향키, Tab, Return은 로컬 입력 버퍼(`localTextBuffer`)를 비운다. 커서가 움직였을 수 있기 때문이다.
- 영문 모드: 조합 중인 글자가 있으면 확정하고 `false`를 돌려준다. 키 처리는 앱이 한다.
- 한자 후보창이 떠 있으면 키를 후보창에 먼저 넘긴다.
- ⌘·⌃·⌥가 눌린 키: 조합을 확정하고 앱으로 넘긴다(단축키).
- 글자 키 26개는 현재 라틴 배열이 만든 문자가 아니라 키 위치(`QwertyKeyMap`, US QWERTY)로 해석한다. Dvorak·Colemak·AZERTY에서도 같은 자모가 나오고, 윗줄 자모는 Shift로만 고른다(Caps Lock 무시). 그 밖의 키는 배열이 만든 문자를 그대로 쓰며 조합 엔진에 넘기지 않는다. 단, 글자 키에 문장부호를 둔 배열(AZERTY의 M 자리 쉼표, Dvorak의 Q W E 자리 `' , .`, Colemak의 P 자리 `;`)에서는 그 문장부호가 자모에 밀려 칠 키가 없어지므로, 숫자·문장부호 키를 US 위치로 읽는다(`LatinLayoutObserver`, `QwertyKeyMap.punctuation`). 판정은 입력을 보고 한다. 글자 키가 글자가 아닌 문자를 한 번 쳐야 켜지므로, 입력기가 시작된 뒤 그 키(AZERTY라면 ㅡ)를 처음 치기 전까지는 배열의 문자가 그대로 나온다. 각 글자 키는 마지막으로 친 문자로 판정하므로, 배열이 바뀌면 해당 글자 키를 다시 칠 때 따라간다. dead key 뒤처럼 두 글자 이상이 온 입력은 판정에 쓰지 않는다. US 위치로 읽을 때 숫자는 Shift 없이 나오고(AZERTY와 반대), ISO 자판과 위치가 엇갈리는 키 50(`` ` ``/`~`)은 제외한다. 독일어·북유럽처럼 글자 키가 모두 글자인 배열은 ö·ü 같은 문자를 그대로 친다.
- 특수 키
  - Return: 조합을 확정하고 키는 앱으로 넘긴다. GoodNotes는 줄바꿈을 직접 넣고, Hermes는 확정만 하고 키를 소비한다(`ClientCompatibilityPolicy`).
  - Esc: 조합 중이면 취소하고 소비, 아니면 앱으로 넘긴다.
  - Space: 조합을 확정하고 공백을 넣는다. macOS의 "스페이스를 두 번 눌러 마침표 추가"가 켜져 있으면 한글 뒤의 빠른 두 번째 공백을 ". "로 바꾼다(`TextConvenienceHandler`, 0.45초 이내).
  - 방향키, Tab: 확정하고 앱으로 넘긴다.
  - Backspace: 조합 중이면 자모를 하나 지운다. 마지막 자모를 지울 때는 그 자모를 확정하고 키를 앱에 넘겨 앱이 직접 지우게 한다. macOS 27의 Apple 두벌식과 같은 순서이며, 조합 취소를 확정으로 처리하는 Figma에서 자모가 남지 않게 한다.
- 나머지는 libhangul로 조합하고, 확정 문자열과 조합 문자열을 어댑터에 전달한다. 음절이 넘어갈 때는 항상 앞 음절을 확정한 뒤 새 조합을 표시한다.

### 조합 종료 단일 경로 (`InputSession.finalize(reason:)`)

조합을 끝내는 모든 사건이 이 함수 하나로 모인다. 이유(`CompositionFinalizeReason`)는 기록용이며 처리 방식은 같다.

| 이유 | 발생 시점 |
|---|---|
| `appDeactivate` | 세션의 앱이 비활성화될 때(`NSWorkspace` 알림). 앱이 아직 입력을 받는 가장 이른 시점이다 |
| `deactivateServer` | IMK가 포커스를 옮길 때. 위에서 이미 확정했다면 아무 일도 하지 않는다 |
| `mouseCommit` | 조합 영역 밖을 클릭해 IMK가 `commitComposition:`을 부를 때 |
| `modeTransition` | 사용자 전환키 |
| `systemModeSwitch` | macOS가 다른 PriType 모드를 선택했을 때(Caps Lock, 입력 메뉴) |

확정은 `insertText(문자열, replacementRange: NSNotFound)` 한 번이다. 앱이 자기 조합 영역을 확정 문자열로 바꾼다. 확정할 문자열이 없는데 조합 영역이 남아 있으면 빈 문자열로 그 영역을 지운다. 직접 삽입 모드에서는 글자가 이미 문서에 있으므로 엔진만 비운다. 조합 중이 아니면 아무 일도 하지 않으므로 여러 번 불려도 안전하다.

포커스 상실 감시자(`armFocusLossFinalizer`)는 세션 자신의 앱만 본다. `deactivateServer`에서 반드시 해제해, 늦게 도착한 알림이 공유 조합기에 있는 다음 세션의 글자를 이전 클라이언트로 확정하지 않게 한다.

## 텍스트 전달 방식 (`TextDelivery.swift`)

`TextDeliveryPolicy.mode(for:)`가 세션마다 한 번 정한다.

| 방식 | 조건 | 동작 |
|---|---|---|
| `immediate` | Finder이고, 조합 표시 속성이 없거나 바탕화면으로 보일 때(좌표 50pt 미만) | 조합을 표시하지 않고 확정만 보낸다 |
| `directInsertion` (실험) | 설정의 "윈도우식 직접 입력"이 켜져 있거나 Hermes이고, 선택 영역을 제대로 알려 주며(`documentAccessSafe`), Electron·브라우저 차단 목록에 없을 때 | 조합 중인 글자를 실제 텍스트로 넣고 키마다 제자리에서 고쳐 쓴다. 선택 영역이 이상하면 조합 표시 방식으로 돌아간다 |
| `markedText` | 그 밖의 모든 경우(기본) | `setMarkedText`로 조합을 표시하고 `insertText`로 확정한다 |

조합 밑줄: `PreeditUnderline`은 Blink 계열(Chromium·Electron)에는 거의 투명한 밑줄색을, 그 밖에는 밑줄 없음 속성을 보낸다. macOS 26부터는 시스템이 입력기의 조합 속성을 버리고 자체 밑줄을 그리므로, 이 속성은 그 이전 버전에서만 효과가 있다. 밑줄 없는 입력은 직접 삽입 방식으로만 가능하다.

## 한/영 전환

### 전환키

`RightCommandSuppressor`가 전용 스레드의 `CGEventTap`으로 전환키(기본 우측 ⌘)와 한자키(기본 우측 Option)를 감지한다. 설정 창의 키 녹음으로 수정키 하나, 일반 키, 조합 키 모두 등록할 수 있다.

- 전환 시점(`ToggleTrigger`, 전환키가 수정키 하나일 때만)
  - 누르는 순간(`press`, 기본): 키를 삼키고 즉시 전환한다. 누르고 있는 동안 다른 키에서 그 수정키를 떼어 내므로 우측 ⌘ + C는 c를 입력한다.
  - 단독 탭(`tapAlone`): 수정키를 앱에 그대로 넘기고, 다른 키, 클릭, 한자키 없이 1초 안에 떼면 전환한다. 우측 ⌘ + C는 복사다. 이 모드에서만 이벤트 탭이 클릭도 받으며, 설정을 바꾸면 탭을 다시 만든다.
  - 두 키 모니터가 같은 `ModifierTapDetector`로 시간을 잰다. 다만 보는 것이 다르다. IOKit 경로는 키보드만 보므로 ⌘-클릭을 알지 못하고, 대신 수정키보다 먼저 눌려 있던 일반 키도 알아챈다.
- 전환 제외 앱(`ToggleExclusionPolicy`): 원격 데스크톱·가상 머신처럼 자체 입력기를 쓰는 앱이 앞에 있으면 전환키와 한자키를 가로채지 않고 그대로 넘긴다.
- Caps Lock 입력 소스 전환이 켜져 있으면 PriType 전환키는 동작하지 않는다(설정 창에서 안내).

### 순서 보장 (`InputModeCoordinator`)

탭 스레드는 전환키와 한자키를 누른 순간 키 시각과 함께 한 대기열에 기록하고 메인 큐로 넘긴다. 키 입력은 앱 → IMK → `handle()`로 따로 도착하므로 둘의 도착 순서는 보장되지 않는다. 그래서 `handle()`은 조합 전에 자기 키보다 먼저 눌린 동작만 실행한다. 전환 직후 친 키는 새 모드로, 한자키 직후 친 후보 선택 키는 후보창으로 가고, 전환 직전에 친 키는 이전 모드에 남는다. 전환키와 한자키도 서로 순서를 지킨다.

### 전환 처리 (`PriTypeInputController.performPriTypeModeTransition`)

1. 조합을 확정한다(`finalize(.modeTransition)`).
2. 로컬 입력 버퍼를 비우고 `HangulComposer.setInputMode`로 모드를 바꾼다. 열린 한자 후보창은 닫힌다.
3. 영문 모드가 되면, 켜져 있는 로마자 자판(ABC, 없으면 U.S.)을 앱에 지정한다(`overrideKeyboardWithKeyboardNamed`). 영문 키는 이 자판으로 입력된다.
4. 메뉴 막대의 입력 소스 표시가 따라오도록 macOS에 선택된 PriType 모드를 알린다(`systemModeReporter` → `InputSourceManager.selectPriTypeMode`). 조합기는 이미 전환됐으므로 메인 큐에서 나중에 실행한다. Apple ABC 입력 소스는 선택하지 않는다.

### macOS가 모드를 선택할 때 (`setValue(_:forTag:client:)`)

Caps Lock, 입력 메뉴, 그리고 4단계 통보에 대한 응답이 모두 이 경로로 들어온다.

- 통보의 응답(에코): `SystemModeEchoFilter`가 PriType이 보낸 통보를 기억했다가 그 응답은 기록만 하고 적용하지 않는다. 빠른 연속 전환에서 늦게 도착한 응답이 모드를 되돌리지 않게 하기 위해서다. 선택이 실패한 통보는 거두고, 사용자가 실제로 입력 소스를 바꾸면 남은 통보를 지우며, 응답 없는 통보는 1초 뒤 만료된다.
- 재확인: 포커스가 바뀔 때마다 IMK는 현재 입력 소스를 다시 알린다. 직전에 본 값과 같으면 무시한다. 무시하지 않으면 전환키로 바꾼 모드가 포커스를 옮길 때마다 되돌아간다.
- 실제 선택: 이 컨트롤러가 공유 조합기의 주인이면 조합을 확정하고 모드를 바꾼다. 주인이 아니면 값을 보류했다가 활성화될 때 적용하되, 그 사이 다른 선택이 있었으면 버린다(`DeferredInputMode`).

### 키 모니터와 권한

| 경로 | 필요 권한 | 특징 |
|---|---|---|
| `RightCommandSuppressor` (CGEventTap, 기본) | 손쉬운 사용 | 전용 스레드(`EventTapThread`, QoS userInteractive)에서 동작한다. 모든 키가 이 콜백을 거쳐 앱으로 가므로 메인 스레드가 바빠도 타이핑이 늦어지지 않는다. 키를 삼킬 수 있다 |
| `IOKitManager` (IOHIDManager, 대체) | 입력 모니터링 | 탭 생성에 실패하거나, 탭이 60초 이내 간격으로 세 번 연달아 꺼지면(`EventTapFailureTracker`) 넘겨받는다. 탭 하나가 넘기는 일은 한 번뿐이며, 탭을 다시 시작하면 새로 센다. 키를 볼 수만 있고 막을 수는 없으므로, 누르는 순간 모드에서는 우측 ⌘ + C가 전환과 복사를 함께 한다. 규칙은 `HIDShortcutState`에 있다 |

## 한자

### 사전 (`HanjaDictionary`, `HanjaManager`)

- 원본은 libhangul의 `Tools/hanja/hanja.txt`(항목 303,494개, 키 222,709개)다. `PriTypeHanjaCompiler`가 이를 키의 UTF-8 바이트 순으로 정렬한 바이너리 `Resources/hanja.dat`로 만든다. 헤더, 원본 라이선스, 레코드 오프셋 표, `키\n(한자\t뜻\n)*` 레코드로 구성된다.
- 컴파일할 때 두 음절 이상 단어의 후보는 원본에 뜻이 적힌 것(흔히 쓰는 단어)을 앞으로 올린다. 원본은 한자 코드 순이라 한국 → 寒國이 韓國보다 앞섰다. 한 음절 후보는 원본 순서 그대로다.
- 앱은 파일을 메모리 매핑하고 이진 탐색한다. 로딩은 헤더와 오프셋 표 검증뿐이라 약 1ms이고, 검색이 건드린 페이지만 메모리에 올라온다.
- 앱 시작 시 백그라운드에서 미리 매핑한다. 다른 스레드가 매핑하는 중에 들어온 검색은 기다리지 않고 빈 결과를 돌려준다.
- 테스트가 커밋된 `hanja.dat`가 원본과 일치하는지, 검색 결과가 libhangul `HanjaTable`과 같은지 확인한다.
- 설정에서 한자 변환을 끄면 매핑을 해제하고, 두 키 모니터 모두 한자키를 가로채지 않는다.

### 검색

- 단어 단위(`searchWord(endingWith:)`): 조합 중인 글자와 로컬 입력 버퍼(없으면 앱이 알려 주는 커서 앞 글자)에서 끝의 한글 음절을 최대 10개 모은다. 가장 긴 끝말부터 한 음절까지 차례로 사전을 찾는다. "대한민국" → 大韓民國, 民國, 國….
- 자모 특수문자: 자음 하나를 조합 중일 때는 `jamo_symbols.json`(자음 14개, 특수문자 390개)에서 찾는다. libhangul이 주는 초성 자모(U+1100~)는 호환 자모(U+3131~)로 바꿔 찾는다.
- 입력 버퍼는 같은 앱에서 친 것만 쓴다. 다른 앱에서 키를 치면 비워진다(입력창을 떠날 때 확정한 마지막 음절이 다음 앱의 단어에 붙지 않게). 한자키를 누른 앱이 마지막으로 키를 친 앱과 다르면 버퍼를 보지 않는다. 방향키, Tab, Return, 단축키, 모드 전환, 클릭 확정, 후보창 밖 클릭 때도 비워진다.

### 선택과 교체

후보는 자기 한글 부분만 바꾼다(`replacementRange` = 커서 앞 한글 길이). 앱이 커서 앞 글자를 알려 주면, 한 음절이든 단어든 그 글자가 후보의 한글과 같을 때만 바꾼다(`canReplace`). 입력기가 모르는 클릭으로 커서가 옮겨졌거나 문서가 NFD라 글자가 맞지 않으면 선택을 취소한다. 커서가 후보의 한글 길이보다 앞에 있어도 취소한다. 커서 앞 글자를 알려 주지 않는 앱(nil 또는 빈 문자열)에서는 확인 없이 바꾸고, 커서 위치를 알려 주지 않는 앱(`NSNotFound`, 비정상 값)에서는 커서 위치에 넣는다. 후보창을 연 뒤 클라이언트가 바뀌었어도 취소한다.

### 후보창 (`HanjaCandidateWindow`)

- `NSPanel`(비활성, 모든 Spaces, 화면 보호기 위 레벨)에 SwiftUI로 그린다. macOS 26부터는 Liquid Glass 배경이다. 한 쪽에 9개씩 보여 준다.
- 키
  - 1~9: 선택
  - Return: 쪽의 첫 후보 선택
  - ↓, Tab, `]`: 다음 쪽
  - ↑, `[`: 이전 쪽
  - Esc: 닫기
  - ←, →: 닫고 앱으로 넘긴다
  - 그 밖의 키: 닫고 평소처럼 입력한다
- 창이 떠 있는 동안에는 이벤트 탭이 후보창 키를 직접 가로챈다(`shownPageCandidates`, `route`). Terminal처럼 조합 중인 글자가 없으면 Esc·방향키·Return을 입력기에 넘기지 않는 앱이 있기 때문이다. 숫자는 키 위치로 인식하며, 현재 쪽에 후보가 없는 숫자는 창을 닫고 앱으로 넘긴다.
- 닫히는 경우: 선택, Esc, 한자키 다시 누르기, 한/영 전환, 포커스가 다른 창이나 앱으로 이동, 후보창 밖 클릭, 한자 변환 끄기.
- 포커스 이동은 두 곳에서 닫는다. 주인 컨트롤러의 `deactivateServer`, 그리고 다른 컨트롤러가 공유 조합기를 넘겨받는 `claimActiveController`다. IMK는 새 입력창을 먼저 활성화하고 이전 입력창을 나중에 비활성화하기도 하는데, 그때 이전 컨트롤러는 이미 주인이 아니어서 창을 닫지 않는다.
- 후보창 밖 클릭은 창이 떠 있는 동안만 거는 전역 마우스 모니터로 감지한다. 조합 중인 글자가 없으면 IMK는 클릭을 입력기에 알리지 않으므로, 이것이 없으면 클릭으로 옮긴 커서 앞 글자를 다음 숫자키가 바꿀 수 있다. 후보창 자체의 클릭은 PriType 앱으로 오므로 이 모니터에 잡히지 않는다. 클릭으로 닫으면 입력 버퍼도 비운다(`onClickOutside`). 커서가 옮겨졌을 수 있어 버퍼가 더는 커서 앞 글자가 아니기 때문이다.

### 후보창 위치 (`CursorRectResolver`, `HanjaCandidateWindow.panelOrigin`)

한자키를 누르면 조합을 확정하기 전에 커서 위치를 구한다. Chromium 계열은 확정 직후 좌표를 비동기로 갱신하기 때문이다.

1. `firstRect(forCharacterRange:)`: 조합 영역, 없으면 선택 영역.
2. 1이 무효이면 `attributes(forCharacterIndex:lineHeightRectangle:)`. 인덱스 0을 먼저 묻고(Squirrel·macSKK·fcitx5와 같음), 무효이면 커서 앞 글자의 문서 인덱스를 묻는다. Google Docs에서 측정해 보니 `firstRect`는 모든 범위에서 쓰레기값이었고, 인덱스 0은 커서를 돌려주었으며, 1 이상의 인덱스는 창 모서리 근처의 고정된 자리를 돌려주었다.
3. 같은 클라이언트(입력창)의 직전 한자 검색에서 얻은 좌표. 다른 클라이언트의 좌표는 쓰지 않는다. 그 입력창은 다른 창이나 다른 모니터에 있을 수 있다.
4. 손쉬운 사용 API: 포커스된 요소의 `AXSelectedTextRange`와 `AXBoundsForRange`, 안 되면 요소의 위치와 크기. 손쉬운 사용 좌표(주 화면 왼쪽 위 기준, y 아래로)는 주 화면(메뉴 막대가 있는 화면)의 높이로 뒤집는다. Chromium이 y만 주는 응답 `(0, y, 0, 0)`은 요소의 x로 보충하며, 주 화면 위나 왼쪽 모니터의 음수 y도 받는다.
5. 마우스 위치.

유효성(`isValidCursorRect`): 값이 모두 유한하고, 높이가 양수이며, x·y의 절댓값이 1보다 크고, 원점이 연결된 화면 안에 있어야 한다. 음수 좌표는 주 화면 왼쪽·아래의 보조 모니터에서 정상이므로 부호는 보지 않는다.

배치: 후보창은 커서 오른쪽 4pt, 그리고 커서보다 글자 높이 하나 더 아래(간격 6pt)에 놓는다. IMK가 알려 주는 좌표가 실제 글자보다 한 줄 위에 있는 앱이 많아서다(메모, TextEdit, Terminal, KakaoTalk에서 측정). 아래에 자리가 없으면 커서 위로 올리고 화면 안으로 맞춘다.

## Secure Input

`IsSecureEventInputEnabled()`는 시스템 전역 플래그라서, 비밀번호 칸이 켠 뒤 끄지 않으면 다른 앱에도 남는다. `SecureInputPolicy`는 다음과 같이 판단한다.

- 시스템 보안 클라이언트(`SecurityAgent`, `loginwindow`, `screencaptureui`)는 항상 그대로 통과시킨다.
- 그 밖에는 전역 플래그가 켜져 있을 때만 필드를 확인한다. 선택 영역이 없거나(`NSNotFound`) 조합 표시 속성이 없으면 통과시키고, 정상 필드에서는 남아 있는 플래그를 무시하고 한글을 조합한다.
- 통과시킬 때는 조합을 앱에 보내지 않고 버린다(비밀번호 칸에 `setMarkedText`를 보내면 경고음이 난다).

## 입력 소스 관리 (`InputSourceManager`)

한/영 전환의 주체가 아니다. 하는 일은 다음과 같다.

- `selectPriTypeMode`: 전환 결과를 macOS 입력 소스 표시에 반영한다(위 전환 처리 4단계).
- `enabledRomanKeyboardLayoutID`: 영문 모드에서 앱에 지정할 로마자 자판을 찾는다.
- `disableABCKeyboardLayout`: 설정 창의 "ABC 입력 소스 끄기". HIToolbox 설정을 고치고 `TextInputMenuAgent`를 재시작한다. 이 프로세스의 TIS 캐시는 갱신되지 않으므로, 결과는 자기 자신을 `--abc-layout-status`로 새로 실행해 확인한다(`ABCLayoutStatusProbe`, 최대 약 3초 재시도 `ABCRemovalVerification`).
- `cleanupStaleInputSources`: 오래된 PriType 항목과 중복을 HIToolbox 설정에서 지우는 유지보수 도구다. 세 키의 정리본을 모두 계획한 뒤 함께 쓰고, 되읽기 검증에 실패하면 함께 되돌린다. 시작할 때 자동으로 실행하지 않는다.

## 설정 창 (`SettingsWindowController`)

SwiftUI, 460×700. 위에서부터 다음과 같다.

1. Caps Lock 입력 소스 전환 상태 카드(macOS 설정 열기)
2. 키 설정
   - 한/영 전환키: Caps Lock 전환이 켜져 있으면 비활성
   - 전환 시점: 누르는 순간 / 단독으로 탭
   - 한자 변환 켜기
   - 한자 입력키
   - 두 키가 같을 때 경고, macOS 단축키를 가릴 때 경고
3. 업데이트: 자동 확인, 지금 확인
4. 시스템 옵션: 손쉬운 사용 권한, 입력 모니터링 권한, ABC 입력 소스 끄기
5. 전환키 제외 앱: 목록, 추가, 삭제
6. 실험적 기능: 윈도우식 직접 입력

## 업데이트

`UpdateChecker`가 GitHub Releases API에서 가장 높은 정식 릴리스(초안·사전 릴리스 제외)를 찾아 버전을 비교한다. 마지막 성공 후 24시간이 지나야 다시 확인한다. 새 버전이 있으면 `UpdateNotifier`가 알림을 보내고, 누르면 릴리스 페이지를 연다. 알림 권한은 처음 보낼 때 요청한다.

## 동시성

| 스레드 | 하는 일 |
|---|---|
| 메인 | IMK 콜백 전부, 조합기, 후보창·설정 창(AppKit·SwiftUI), `NSWorkspace` 알림, IOKit 대체 경로의 HID 콜백, 권한 확인 타이머 |
| 이벤트 탭(`com.pritype.eventtap`) | CGEventTap 콜백. 전환·한자 동작을 기록하고, 후보창 키를 가로채고, 수정키를 떼어 낸다 |
| 백그라운드 | 한자 사전 미리 매핑, 업데이트 확인, ABC 상태 확인용 하위 프로세스, 디버그 로그 기록 |

| 잠금 | 보호 대상 |
|---|---|
| `RightCommandSuppressor.lock` (재귀) | 탭의 모든 상태와 콜백. 콜백 전체 동안 잡는다. 콜백이 `stop()`을 부를 수 있어 재귀 잠금이다 |
| `ConfigurationManager.keyBindingLock` | 탭이 키마다 읽는 값의 캐시: 전환키·한자키 바인딩, 전환 시점, 한자 켜짐 |
| `InputModeCoordinator.pendingActions` | 탭 스레드가 기록한 전환·한자 동작 대기열 |
| `HanjaManager.condition` | 사전 로딩 상태. 미리 매핑만 기다리고 검색은 기다리지 않는다. 매핑된 사전 자체는 읽기 전용이다 |
| `HanjaCandidateWindow.acceptingKeysState` | 탭이 읽는 후보창 표시 여부 |
| `ToggleExclusionPolicy.lock` | 앞에 있는 앱과 제외 목록 |
| libhangul `ThreadSafeHangulInputContext` | 조합 엔진 내부 상태 |

컨트롤러의 정적 상태(`sharedController`, 마지막 시스템 모드, 에코 필터, `systemModeReporter`)와 조합기는 메인 스레드에서만 쓴다. IMK가 메인에서 호출한다는 전제이며 컴파일러가 강제하지는 않는다. 디버그 빌드는 IMK 콜백에서 이를 단언한다.

## 모듈

### 타깃

| 타깃 | 종류 | 역할 |
|---|---|---|
| `PriType` | 실행 파일 | 앱 진입점(`main.swift`). 번들에서는 `PriTypeV2` |
| `PriTypeCore` | 라이브러리 | 입력기 로직 전부. 외부 의존성은 libhangul-swift 하나이며 테스트한 리비전에 고정한다 |
| `PriTypeIMKHarness` | 라이브러리 | 실제 `PriTypeInputController`를 가짜 입력창(`FakeTextClient`)에 연결해 키를 흘려 넣는 통합 테스트 도구. 한자 후보창은 `FakeCandidatePresenter`가 대신해 후보를 기록하고 선택·클릭을 흉내 낸다. `Dubeolsik`은 한글 문장을 두벌식 키로 바꾼다 |
| `PriTypeHanjaCompiler` | 실행 파일 | `hanja.txt` → `hanja.dat` 컴파일 |
| `PriTypeBenchmark` | 실행 파일 | 한자 사전·검색, 자모 검색, 동시성, 좌표 검증, 타이핑 경로 지연 측정([BENCHMARK.md](BENCHMARK.md)) |
| `PriTypeVerify` | 실행 파일 | CI에서 돌리는 조합 동작 점검 |
| `PriTypeCoreTests` | 테스트 | 유닛·통합 테스트 |

### `PriTypeCore` 파일

| 파일 | 역할 |
|---|---|
| `PriTypeInputController` | `IMKInputController` 서브클래스. IMK 수명 주기, 세션 관리, 모드 전환 처리, 시스템 모드 수신, IMK 메뉴 |
| `InputSession` | 세션 하나의 클라이언트, 컨텍스트, 전달 어댑터, 중복 키 상태, 포커스 상실 감시. 조합 종료 단일 경로 |
| `TextDelivery` | 전달 방식 결정과 어댑터 3종, 조합 밑줄 속성 |
| `DirectInsertionPlanner` | 직접 삽입의 교체 범위 계산과 검증, 짧은 간격의 중복 키 판정 |
| `ClientContextDetector` | 클라이언트 분석(`ClientContext`). 활성화 때는 클라이언트 IPC를 거의 하지 않는 가벼운 분석, 첫 키에서 전체 분석. 앱별 호환 정책(`ClientCompatibilityPolicy`) |
| `SecureInputPolicy` | Secure Input 통과 판정 |
| `HangulComposer` | 한글 조합, 특수 키, 로컬 입력 버퍼, 한자 검색과 교체. `inputMode`가 한/영 상태의 유일한 원본이다 |
| `HangulComposerTypes` | `HangulComposerDelegate` 프로토콜, `InputMode` |
| `CompositionHelpers` | libhangul 출력(UCSChar 배열)을 NFC 문자열로 변환 |
| `TextConvenienceHandler` | 한글 조합 중 더블스페이스 마침표 |
| `KeyCode` | 키 코드 상수, `QwertyKeyMap`(글자 키 위치 → QWERTY 글자, 숫자·문장부호 키 → US 문자), `LatinLayoutObserver`(글자 키에 문장부호를 둔 배열 감지) |
| `InputModeCoordinator` | 전환·한자 동작의 키 순서 대기열, `SystemModeEchoFilter`, `DeferredInputMode` |
| `RightCommandSuppressor` | CGEventTap 키 모니터, `EventTapThread` |
| `IOKitManager` | IOHIDManager 대체 키 모니터, 손쉬운 사용·입력 모니터링 권한 확인 |
| `HIDShortcutState` | IOKit 경로의 단축키 판정(HID usage 대응표, 장치별 눌린 키, 30초 만료, 한자키 0.5초 디바운스) |
| `ToggleTrigger` | 전환 시점 설정과 `ModifierTapDetector` |
| `KeyMonitorLifecycle` | 탭 실패 추적(`EventTapFailureTracker`), 좌우 수정키 상태(`ModifierKeyState`) |
| `ToggleExclusionPolicy` | 전환키 제외 앱 판정 |
| `KeyRecordingState`, `KeyRecordingSessions` | 설정 창 키 녹음 상태, 한 번에 한 행만 녹음 |
| `HanjaManager` | 한자·자모 검색, 사전 로딩 상태, 단어 끝말 검색 |
| `HanjaDictionary` | 매핑 한자 사전의 형식, 이진 탐색, 컴파일러 |
| `HanjaCandidateWindow` | 한자 후보창, 키 처리와 이벤트 탭 라우팅, 배치 |
| `CursorRectResolver` | 후보창 좌표 전략과 유효성 검증 |
| `InputSourceManager` | TIS 조회, PriType 모드 선택, ABC 끄기, 유지보수 정리 |
| `ABCLayoutStatusProbe`, `ABCRemovalVerification` | ABC 끄기 결과를 새 프로세스로 확인 |
| `ConfigurationManager` | 사용자 설정(`UserDefaults`), 키 바인딩 이관, macOS 더블스페이스 설정 읽기. `ConfigurationProviding`으로 테스트에서 대체 가능 |
| `SettingsWindowController` | 설정 창 |
| `UpdateChecker`, `UpdateNotifier`, `ReleaseChannel` | 업데이트 확인, 알림, 정식·베타 채널 판정 |
| `AboutInfo` | 버전 정보, 정보 창 |
| `L10n` | 한국어·영어 문자열 |
| `PriTypeConfig` | 상수: 자판 ID `"2"`(두벌식), Finder 바탕화면 판정 50pt, 설정 창 크기, 더블스페이스 0.45초, 디버그 로그 경로 |
| `DebugLogger` | 디버그 빌드: `~/Library/Logs/PriType/pritype_debug.log`(5MB에서 교체). 민감한 내용은 가린다. 컨트롤러마다 처음 200개 키 입력의 키 코드를 기록하므로, 실기기 테스트 뒤에는 로그를 지운다. 릴리스 빌드: 빈 함수 |

## 테스트

```bash
swift test
```

Swift Testing 기반, 377개 테스트와 57개 Suite(2026-09-19 기준). Command Line Tools에는 Testing 모듈이 없으므로 Xcode 툴체인이 필요하다.

- 유닛 테스트: 조합, 키 위치, 전달 정책, 직접 삽입, 키 모니터(탭 이벤트 순서, IOKit 판정, 탭 스레드, 순서 대기열, 에코 필터), 한자 사전·검색·후보창 배치, 설정 이관, 입력 소스 정리, 업데이트 버전 비교, 등록 계약.
- 통합 테스트(`IMKIntegrationTests`): `PriTypeIMKHarness`로 실제 컨트롤러를 돌린다. 확정 순서, 백스페이스, 중복 키, 한/영 전환(전환키, 대기열, Caps Lock, 재확인), 포커스 전환, 긴 문단 왕복 입력, 한자(단어 변환, 짧은 끝말 교체, 커서가 옮겨진 뒤의 선택 취소, 클릭으로 닫은 뒤의 버퍼, 다른 앱의 글자, 늦은 비활성화)를 검증한다. 하니스는 macOS에 모드를 통보하는 부분을 기록만 하고 한자 후보창은 패널을 열지 않으므로, 테스트가 실제 입력 소스를 바꾸거나 창을 띄우지 않는다. 이벤트 탭의 후보창 키 라우팅과 클릭 감시는 실제 이벤트가 필요해 다루지 않는다.
- `swift run PriTypeVerify`: 조합 동작 점검(CI에서 실행).
- `swift run -c release PriTypeBenchmark`: 성능 측정.

## 빌드와 배포

| 스크립트 | 하는 일 |
|---|---|
| `install.sh` | 릴리스 빌드, 앱 번들 조립, 서명(지정한 인증서 → Apple Development → 자체 서명 `PriTypeDev` → ad-hoc), `~/Library/Input Methods`에 설치 |
| `build_release.sh` | 릴리스 빌드, Developer ID 서명, `/Library/Input Methods`에 설치하는 pkg 생성, 공증과 스테이플. 결과는 `PriTypeV2_Release.pkg` |
| `build_debug.sh` | 같은 흐름의 디버그 빌드 pkg |
| `distribute.sh` | 서명한 앱을 zip으로 묶고 선택적으로 공증 |
| `Packaging/scripts/` | pkg의 `preinstall`(이전 버전 제거), `postinstall`(입력 관련 프로세스 재시작, 새 설치면 입력 소스 설정 열기) |

CI(`.github/workflows/ci.yml`)는 push와 PR마다 빌드, `swift test`, `PriTypeVerify`, SwiftLint(`--strict`)를 돌린다. `release.yml`은 `v*` 태그에서 태그와 Info.plist 버전·채널이 맞는지 확인하고, 서명 전용 러너에서 `build_release.sh`로 pkg를 만들어 GitHub 릴리스에 올린다.

## 디렉터리 구조

```
PriType-Swift/
├── Sources/
│   ├── PriType/                 # 앱 진입점
│   ├── PriTypeCore/             # 입력기 로직 (위 표)
│   │   └── Resources/
│   │       ├── hanja.dat        # 컴파일된 한자 사전 (6.9MB, 키 222,709개)
│   │       ├── jamo_symbols.json
│   │       ├── ko.lproj/, en.lproj/
│   ├── PriTypeIMKHarness/       # IMK 통합 테스트 도구
│   ├── PriTypeHanjaCompiler/    # 한자 사전 컴파일러
│   ├── PriTypeBenchmark/
│   └── PriTypeVerify/
├── Tests/PriTypeCoreTests/
├── Tools/
│   ├── hanja/hanja.txt          # 한자 사전 원본 (libhangul, BSD)
│   └── generate_assets.swift, ime-attr-probe/
├── Resources/                   # 앱 번들 리소스 (InfoPlist.strings)
├── Packaging/scripts/           # pkg 설치 스크립트
├── Docs/                        # 설계 계획과 리뷰 기록
├── Info.plist, PriType.entitlements
├── install.sh, build_release.sh, build_debug.sh, distribute.sh
└── Package.swift
```
