# KakaoTalk 중복 keyDown 캡처 · 2026-09-20

리뷰(`../CodeReview-2026-09-20.md`) 1번은 `KeyEventDedup`의 50ms 창을 좁히기 전에
**실제 중복 전달 표본에서 보존되는 이벤트 식별 정보를 먼저 확인하라**고 했다.
`b4cdcae`는 그 표본 없이 timestamp 완전 일치로 좁혔고, 이 문서가 그 표본이다.

## 환경

macOS 27.0, Apple silicon, 카카오톡 26.8.0(`com.kakao.KakaoTalkMac`),
`/Library/Input Methods/PriTypeV2.app` 디버그 빌드(`PriTypeDev` 서명,
`-D PRITYPE_UNREDACT_SENSITIVE_LOGS`), `com.pritype.dedupProbe = YES`.

프로브는 `DuplicateKeyProbe`다. keyDown마다 이전 키와의 식별자 일치 여부,
auto-repeat 여부, 두 timestamp의 차, dedup 판정을 기록한다.

## 실행

| 조건 | 입력 |
| --- | --- |
| marked text (기본) | `r` 5회, 약 1초 간격 |
| marked text (기본) | `rkr`(각) → 백스페이스 3회, 3라운드 |
| direct insertion ON | `rkr`(각) → 백스페이스 3회 |

direct insertion 라운드에서 `TextDeliveryPolicy: DirectInsertionAdapter
(experimental) for com.kakao.KakaoTalkMac`을 로그로 확인했다. 즉 2026-06에
증상이 관찰된 것과 같은 전달 경로다.

## 결과

| 측정 | 값 |
| --- | ---: |
| 카카오톡 프로브 줄 | 77 |
| `dropped=yes` | 0 |
| `dt=0.000000000` | 0 |
| 최소 `dt` | 0.0649s |

**물리적으로 누른 키 하나가 로그에 두 줄로 찍힌 경우가 한 번도 없다.**
화면 동작도 정상이었다: `r` 5회 → `ㄱ` 5개, `각` + 백스페이스 → `각 → 가 → ㄱ`.

## 읽어낼 수 있는 것

이 버전의 카카오톡은 keyDown을 중복 전달하지 않는다. 글자 키에서도, 백스페이스
에서도, 두 전달 모드 모두에서. 2026-06의 증상("백스페이스 한 번에 자모 두 개",
`0cc14eb`)은 같은 조건에서 재현되지 않는다.

좁힌 규칙이 정상 입력을 막지 않는 것도 확인됐다. 가장 짧은 간격 0.0649s는 옛
50ms 창 바로 바깥이지만, 리뷰가 재현한 30ms 연타는 창 안쪽이었다. 창을 없앤 것은
관측된 손실(빠른 연타)을 고치고, 관측되지 않은 것(중복 전달)에 대해서는 아무것도
잃지 않는다.

## 읽어낼 수 없는 것

재전달이 timestamp를 보존하는지는 **여전히 모른다.** 재전달 자체를 포착하지
못했기 때문이다. 리뷰가 요구한 표본은 "중복이 일어날 때 무엇이 보존되는가"였고,
여기서 얻은 것은 "지금은 중복이 일어나지 않는다"이다. 다른 버전, 다른 창 종류,
다른 조건에서 다시 나타날 수 있다.

따라서 `KeyEventDedup`은 남긴다. 비용이 사실상 없고, 정확한 재전달은 여전히
잡으며, 오탐은 구조적으로 불가능하다. 다만 지금 이 머신에서 그것이 막고 있는
것은 없다.

한 가지 더: 증상이 direct insertion에서만 보고됐다는 사실은 처음부터 이상했다.
중복 전달은 호스트의 이벤트 전달 속성이고, 입력기가 조합을 어떻게 그리는지가
호스트의 전달 횟수를 바꿀 수는 없다. 증상이 다시 나타나면 호스트를 의심하기
전에 어댑터의 읽기-수정-쓰기를 먼저 본다. 프로브가 그 둘을 한 줄로 구분해 준다.

## 다시 돌리는 법

```
defaults write com.pritype.inputmethod.v2 com.pritype.dedupProbe -bool YES
```

디버그 빌드에서만 동작한다. 키코드·문자는 기록하지 않는다(일치 여부와 시간 차만).
끝나면 `defaults delete com.pritype.inputmethod.v2 com.pritype.dedupProbe`.
