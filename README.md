# PriType

<p align="center">
  <strong>macOS 기본 입력 흐름에 맞춘 빠른 한글 입력기</strong><br>
  한글은 PriType 조합, 영어는 ABC 레이아웃 pass-through. 전환은 빠르게, 조합은 가볍게.
</p>

<p align="center">
  <a href="https://github.com/ghostface2232/PriType-Swift/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/ghostface2232/PriType-Swift?label=release"></a>
  <img alt="macOS" src="https://img.shields.io/badge/macOS-14.0%2B-111111">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6.2-F05138">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-blue">
</p>

PriType은 Swift와 InputMethodKit으로 만든 macOS용 한글 입력기입니다. 한글 조합 엔진은 [libhangul-swift](https://github.com/Meapri/libhangul-swift)를 사용합니다.

## 특징

- **빠르고 안정적인 한/영 전환**
  PriType은 한 입력기 안에서 한글 모드와 영어 모드를 함께 관리합니다. 사용자 지정 전환키는 실제 `ABC` 입력 소스를 선택하지 않고 PriType 내부 모드만 전환해, 전환 직후 첫 글자 씹힘과 한/영 상태 불일치를 줄입니다.

- **ABC 레이아웃 pass-through**
  영어 모드에서는 PriType이 문자를 직접 삽입하지 않고, macOS `ABC`/`US` 키보드 레이아웃을 요청한 뒤 host 앱의 기본 입력 흐름으로 통과시킵니다.

- **빠른 한글 조합**
  두벌식 표준 자판을 지원합니다.

- **한자와 자모 특수문자**
  한글 입력 중 한자키를 누르면 커서 앞 단어의 한자 후보를 고를 수 있습니다. "대한민국" 뒤에서 누르면 大韓民國부터, 한 글자 뒤에서 누르면 그 글자의 후보가 나옵니다. 자음 입력 후 한자키를 누르면 `♥`, `★` 같은 자모 특수문자도 입력할 수 있습니다. 한자를 쓰지 않는다면 설정에서 한자 변환을 끌 수 있고, 그러면 사전을 불러오지 않고 한자키는 원래 키로 동작합니다.

- **선택 가능한 전환키**
  macOS Caps Lock 입력 소스 전환을 쓰지 않는 경우, 우측 Command 등 원하는 키를 PriType 한/영 전환키로 지정할 수 있습니다. Caps Lock 전환이 켜져 있으면 PriType 전환키는 자동으로 비활성화됩니다.

- **macOS 설정 연동**
  스페이스 두 번으로 마침표 입력은 PriType 별도 설정이 아니라 macOS 텍스트 입력 설정을 따릅니다.

- **GitHub에서 빌드한 설치 패키지**
  릴리즈 PKG는 GitHub Actions의 깨끗한 macOS VM에서 태그 기준으로 빌드합니다. Apple 공증은 받지 않았으므로 처음 설치할 때 한 번 허용이 필요합니다.

## 설치

1. [최신 릴리즈](https://github.com/ghostface2232/PriType-Swift/releases/latest)에서 `PriTypeV2_Release.pkg`를 다운로드합니다.
2. PKG를 실행해 설치합니다. macOS가 "Apple이 확인할 수 없음"이라며 막으면, `시스템 설정 > 개인정보 보호 및 보안` 아래쪽의 **그래도 열기**를 누른 뒤 다시 실행합니다.
3. `시스템 설정 > 키보드 > 텍스트 입력 > 입력 소스`에서 PriType `한글` 입력 소스를 추가합니다.
4. PriType 내부의 한/영 모드는 사용자 지정 전환키로 즉시 전환됩니다.

PriType 앱 번들은 기본적으로 `/Library/Input Methods/PriTypeV2.app`에 설치됩니다.

## 한/영 전환 설정

### Caps Lock으로 전환

macOS 설정에서 `Caps Lock 키로 ABC 입력 소스 전환`을 켜면, Caps Lock 전환은 macOS가 직접 관리합니다.

이 모드에서는 PriType 설정의 별도 한/영 전환키가 비활성화됩니다. 전환 경로가 둘로 갈라지지 않도록 macOS 입력 소스 전환을 단일 기준으로 사용합니다.

### 우측 Command 등으로 전환

Caps Lock 입력 소스 전환을 쓰지 않는다면 PriType 설정에서 한/영 전환키를 지정할 수 있습니다. 기본값은 우측 Command입니다.

전환키가 우측 Command 같은 수정키 하나라면 전환 시점을 고를 수 있습니다. "누르는 순간"(기본값)은 누르자마자 전환하며, 그 키는 다른 키와 조합되지 않습니다. "단독으로 탭"은 다른 키 없이 눌렀다 떼면 전환하고, 다른 키와 함께 누르면 원래 수정키로 동작합니다(예: 우측 Command + C로 복사).

우측 Command 전환이 동작하지 않으면 `시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용`에서 PriType 권한을 확인한 뒤, 필요하면 권한을 껐다 켜고 Mac을 재시동해 주세요. 손쉬운 사용 방식의 키 감지가 멈추면 PriType은 대체 경로로 넘어가는데, 이 경로에는 `입력 모니터링` 권한이 필요합니다. 두 권한의 상태는 PriType 설정의 시스템 옵션에서 볼 수 있습니다.

## 지원 기능

| 영역 | 내용 |
| --- | --- |
| 자판 배열 | 두벌식 표준 |
| 입력 소스 | PriType 입력 소스 하나(한국어·영문 두 모드), 영문은 ABC/US 자판으로 pass-through |
| 전환 | macOS Caps Lock 입력 소스 전환 또는 PriType 사용자 지정 전환키(누르는 순간 / 단독 탭) |
| 한자 | 단어 단위 한자 후보창, 자모 특수문자 입력, 한자 변환 끄기 |
| 텍스트 편의 기능 | macOS 더블스페이스 마침표 설정 연동 |
| 업데이트 | GitHub Releases 기반 자동 업데이트 확인 |

## 요구사항

- macOS 14.0 Sonoma 이상
- Swift 6.2 이상

## 빌드

```bash
# 개발 빌드
swift build

# 릴리즈 PKG 생성 (기본은 ad-hoc 서명, 서명 방식은 스크립트 상단 참고)
./build_release.sh

# 고정 인증서로 서명 (손쉬운 사용·입력 모니터링 권한이 업데이트 뒤에도 유지됨)
APP_SIGN_IDENTITY="PriType Release" ./build_release.sh
```

## 문제 해결

- **입력 소스가 중복으로 보일 때**
  최신 버전 설치 후 로그아웃/로그인하거나 재시동해 macOS 입력 소스 캐시를 새로 고쳐 주세요.

- **Caps Lock 전환이 안 될 때**
  macOS 입력 소스 설정에서 Caps Lock 전환 옵션이 켜져 있는지 확인해 주세요. PriType 설정에서 Caps Lock을 직접 전환키로 지정하는 방식은 사용하지 않습니다.

- **우측 Command 전환이 안 될 때**
  손쉬운 사용 권한이 필요합니다. 권한을 부여한 뒤에도 동작하지 않으면 PriType을 재실행하거나 Mac을 재시동해 주세요.

## 문서

- [ARCHITECTURE.md](ARCHITECTURE.md): 내부 구조, 입력 처리 흐름, 주요 모듈
- [Docs/History.md](Docs/History.md): 지금의 구조가 왜 이렇게 됐는지에 대한 결정 기록
- [Docs/DeviceVerification.md](Docs/DeviceVerification.md): 설치본을 실제 머신에 대고 검증하는 방법
- [BENCHMARK.md](BENCHMARK.md): 성능 측정 결과
- [CHANGELOG.md](CHANGELOG.md): 버전별 변경 사항

## 라이선스

MIT License
