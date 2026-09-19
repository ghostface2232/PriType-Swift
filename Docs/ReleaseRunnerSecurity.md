# Release runner security

PriType의 CI와 릴리스는 모두 GitHub-hosted macOS VM에서 실행한다. job마다 새 VM이 뜨고 끝나면 버려지므로, 이전 job이 남긴 파일이나 키체인이 다음 job에 남지 않는다.

- `.github/workflows/ci.yml`은 push와 PR마다 `macos-15` VM에서 빌드, 테스트, SwiftLint를 돌린다. 시크릿을 쓰지 않는다.
- `.github/workflows/release.yml`은 `v*` 태그 push에서만 `xcode-27` VM(Xcode 27, macOS 27 SDK)으로 실행한다. 앱이 어떤 AppKit 디자인과 동작을 받는지는 빌드한 SDK 버전이 정하므로, 로컬 빌드와 같은 SDK를 쓴다. GitHub가 이 이미지를 아직 베타로 표시하므로 macOS 27 정식 라벨이 생기면 옮긴다. 포크에서 온 PR은 이 workflow를 실행할 수 없고 저장소 시크릿도 받지 못한다.

## 서명

Apple 개발자 계정이 없으므로 기본은 ad-hoc 서명이고, PKG는 서명·공증하지 않는다.

ad-hoc 서명의 designated requirement는 바이너리 해시(`cdhash`)라서 빌드마다 바뀐다. macOS는 손쉬운 사용·입력 모니터링 허용을 이 요구 조건에 묶으므로, 업데이트할 때마다 사용자가 권한을 다시 허용해야 한다. 시스템 설정에는 켜진 것처럼 보이는데 동작하지 않는 경우가 많아, 사용자는 항목을 지우고 다시 추가해야 한다.

고정 인증서로 서명하면 요구 조건이 `certificate leaf = H"…"`가 되어 업데이트 뒤에도 권한이 유지된다. 자체 서명 인증서면 충분하다. 저장소 `Settings > Secrets and variables > Actions`에 다음을 넣으면 release job이 임시 키체인에 가져와 서명한다.

| 시크릿 | 내용 |
|---|---|
| `RELEASE_SIGNING_P12` | 인증서와 개인 키를 내보낸 `.p12`의 base64 (`base64 -i cert.p12 \| pbcopy`) |
| `RELEASE_SIGNING_P12_PASSWORD` | `.p12` 비밀번호 |
| `RELEASE_SIGNING_IDENTITY` | 인증서 이름 (예: `PriTypeDev`) |

인증서를 바꾸면 요구 조건이 바뀌어 그 업데이트에서 한 번 권한을 다시 받아야 한다. 인증서는 한 번 정하면 유지한다.

## 변경 후 확인

- 태그를 붙이기 전에 Actions 탭에서 Release workflow를 수동 실행(`Run workflow`)하면 빌드와 패키징만 하고 릴리스는 만들지 않는다. PKG는 7일간 workflow artifact로 남는다.

- release job이 GitHub-hosted `xcode-27`로 표시되는지 확인한다.
- job 로그의 `designated =>` 줄이 의도한 서명(ad-hoc이면 `cdhash`, 인증서면 `certificate leaf`)인지 확인한다.
- 시크릿을 넣었다면 Cleanup 단계가 임시 키체인을 지웠는지 확인한다.
