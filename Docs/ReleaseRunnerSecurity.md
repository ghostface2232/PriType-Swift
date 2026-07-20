# Release runner security

PriType의 pull request와 서명 릴리즈는 서로 다른 신뢰 경계에서 실행한다.

- `.github/workflows/ci.yml`은 GitHub-hosted `macos-15` VM과 그 image에 설치된 Xcode 26.3만 사용한다. PR이 수정한 테스트·검증 코드는 영속 호스트에서 실행되지 않는다.
- `.github/workflows/release.yml`은 `self-hosted`, `macOS`, `pritype-signing` label을 모두 가진 전용 runner에서만 실행된다. 일치하는 runner가 없으면 release job은 대기하며 일반 self-hosted runner로 fallback하지 않는다.

## 전용 signing runner 설정

1. PR·일반 개발 작업에 사용하지 않는 별도 macOS runner 또는 매 릴리즈마다 초기화할 수 있는 VM을 준비한다.
2. GitHub의 `Settings > Actions > Runners`에서 해당 runner에만 `pritype-signing` custom label을 부여한다.
3. 조직 runner라면 전용 runner group을 만들고 이 저장소와 release workflow만 접근하도록 제한한다.
4. 다른 workflow에서 bare `runs-on: self-hosted`를 사용하지 않는다. 그런 job도 label이 더 많은 signing runner에 배정될 수 있다.
5. 릴리즈 후 임시 keychain, P12, notary credential이 제거됐는지 확인하고 runner image를 정기적으로 재생성한다.

GitHub는 public repository의 fork pull request가 self-hosted runner에서 위험한 코드를 실행할 수 있고, self-hosted runner는 매 job마다 깨끗한 VM이라는 보장이 없다고 설명한다. 자세한 운영 기준은 [Secure use reference](https://docs.github.com/en/actions/reference/security/secure-use)와 [self-hosted runner label 문서](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/use-in-a-workflow)를 따른다.

## 변경 후 확인

- PR의 `Build and Test`, `SwiftLint` job runner가 GitHub-hosted `macos-15`로 표시되는지 확인한다.
- release job이 `pritype-signing` label 없는 runner에서는 시작되지 않는지 확인한다.
- signing runner의 작업 목록에 pull request event가 한 번도 나타나지 않는지 확인한다.
