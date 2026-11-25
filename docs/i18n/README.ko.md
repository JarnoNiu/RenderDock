<div align="center">

<img src="../../assets/icon.png" width="120" alt="RenderDock 아이콘">

# RenderDock

**Mac에서 돌아가는 모든 렌더링을 떠 있는 캡슐 하나에.**

[English](../../README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · **한국어** · [Español](README.es.md) · [Français](README.fr.md) · [Deutsch](README.de.md) · [Português](README.pt-BR.md) · [Русский](README.ru.md)

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![의존성: 없음](https://img.shields.io/badge/dependencies-none-4FEDB0)
![라이선스: MIT](https://img.shields.io/badge/license-MIT-42C2FF)

<img src="../../assets/demo.gif" width="820" alt="RenderDock 데모: 캡슐이 패널로 펼쳐지고, 화면을 가로질러 드래그된 뒤 모서리에 달라붙는 모습">

<sub>위 UI는 앱이 데모 모드에서 직접 그린 것입니다. 작업, 수치, 포인터는 미리 짜 둔 각본대로 움직이며, 배경은 가상의 데스크톱입니다.</sub>

</div>

---

RenderDock은 스크립트와 터미널에서 렌더링을 돌리는 사람을 위한 작은 macOS 네이티브 앱입니다. 이 컴퓨터에서 실행 중인 헤드리스 Blender 작업을 모두 찾아 각각 어디까지 진행됐는지 보여 주고, 그 일을 처리하는 하드웨어도 함께 지켜봅니다. 설정이 필요 없고, 작업에는 절대 손대지 않습니다.

## 만든 이유

셸 스크립트로 실행한 렌더링에는 창이 없습니다. 결국 `ps`를 실행하고, 출력 폴더의 파일 수를 세고, Mac이 한 시간 전에 잠들어 버린 건 아닌지 걱정하게 됩니다. RenderDock은 이 모든 것을 한곳에 모읍니다. 항상 화면에 있지만 방해가 되지 않습니다.

## 제공하는 것

<table>
<tr>
<td width="50%" valign="top">

**어디에나 둘 수 있는 캡슐**

원하는 디스플레이로 드래그하면 됩니다. 화면 가장자리와 모서리, 위쪽이나 아래쪽 가운데에 달라붙고, 마지막으로 둔 위치를 기억합니다. 전체 화면 앱 위에도 떠 있으며, Spaces를 전환해도 따라옵니다.

<img src="../../assets/capsule-en.png" width="380" alt="접힌 상태의 캡슐">

**클릭 한 번으로 전체 파악**

- 작업 체인마다 카드 한 장: 제목, 프로젝트, 스크립트, 경과 시간
- 샷이 여러 개인 큐에는 구간 막대: 완료(Done), 렌더링 중(Rendering), 일시 정지(Paused), 다음 순서(Up next)
- 진행 중인 샷에 대해서는 최신 프레임의 썸네일, 프레임 수, 프레임당 초, 남은 시간, CPU 코어 수와 메모리
- 구분할 수 있는 상태: 실행 중(Running), 일시 정지(`SIGSTOP`), 정체(Stalled), 대기 중(Queued)

**컴퓨터 상태를 한눈에**

CPU, GPU 사용률과 GPU 메모리, 메모리와 메모리 압력, SoC 온도, 스왑, 디스크 여유 공간, 전원, 그리고 Mac의 잠자기를 막고 있는 것이 있는지 보여 줍니다.

</td>
<td width="50%" valign="top">

<img src="../../assets/panel-en.png" width="400" alt="작업 카드와 시스템 지표가 표시된 펼친 패널">

</td>
</tr>
</table>

이 밖에도 진행률 링이 있는 메뉴 막대 항목, 선택 사항인 **렌더링 중 잠자기 방지**(Keep Awake While Rendering) 스위치, **로그인 시 실행**(Launch at Login)이 있습니다.

0.2의 새로운 기능: [`renderdock run`](../EXACT-PROGRESS.md)으로 실행하면 어떤 렌더링이든 정확한 진행률을 볼 수 있습니다. 작업이 끝나거나 실패하거나 정체되면 Mac과 휴대폰으로 [알림](../NOTIFICATIONS.md)을 보내고, [로컬 API](../API.md)가 있어 다른 표시 장치에서도 같은 진행률을 보여 줄 수 있습니다. 이 세 문서는 현재 영어로만 제공됩니다.

0.3의 새로운 기능: [기록](../HISTORY.md)과 이를 바탕으로 한 큐 전체의 남은 시간 추정, 렌더링 옆에 함께 표시되는 [코딩 에이전트 세션](../AGENT-TASKS.md), [ffmpeg 인코딩](../EXACT-PROGRESS.md#ffmpeg-from-03)의 실제 진행률, 그리고 [ComfyUI](../COMFYUI.md) 큐. 직접 켜기 전까지는 꺼져 있는 기능도 있습니다. 패널에서 [에이전트의 권한 요청에 답하기](../ANSWERING-AGENTS.md), [책상 위의 작은 Bluetooth 디스플레이](../DEVICES.md)(보드 한 종류용 [오픈 펌웨어](../../firmware/desk-display/README.md) 포함), 어떤 스크립트나 에이전트든 알림을 보내고 진행 상황을 보고하고 사용자에게 질문할 수 있는 [다른 프로그램을 위한 입구](../AGENT-ENTRY.md), 그리고 Home Assistant를 위한 [MQTT](../MQTT.md)입니다. 로컬 API를 활용한 [예제](../../examples)도 두 가지 있습니다. 진행률 막대로 쓰는 LED 스트립과 Stream Deck 키입니다. 이 문서들은 현재 영어로만 제공됩니다.

## 빠른 시작

요구 사항: macOS 14 이상, 그리고 Swift 6 툴체인(Xcode 16 이상 또는 Command Line Tools만 설치: `xcode-select --install`).

```bash
git clone https://github.com/JarnoNiu/RenderDock.git
cd RenderDock
zsh scripts/install.sh
```

이 명령은 앱을 빌드해 `/Applications/RenderDock.app`에 복사한 뒤 실행합니다. 관리자 암호도, 내려받을 의존성도 필요 없습니다. `--login`을 붙이면 로그인 시 실행도 함께 켜집니다.

실행 중인 렌더링이 없다면 가상의 작업으로 살펴볼 수 있습니다.

```bash
open -n /Applications/RenderDock.app --args --demo
```

또는 Blender도 GPU도 없이, 실제 프로세스를 잡아내는 모습을 확인할 수 있습니다.

```bash
zsh scripts/fake-render.sh 60 1
```

> 미리 빌드된 다운로드는 아직 없습니다. 앱은 공증(notarize)되지 않았고, 서명되지 않은 앱을 내려받는 것은 30초짜리 빌드보다 번거롭습니다. 서명된 릴리스와 Homebrew cask는 로드맵에 있습니다.

## 렌더링을 찾는 방법

RenderDock은 프로세스 테이블과 출력 폴더를 읽습니다. Blender에 후킹하지 않으며, 스크립트를 고칠 필요도 없습니다.

| 감지하는 것 | 표시하는 것 |
|---|---|
| `-b` / `--background`로 시작된 Blender 프로세스 | **샷** |
| 프로세스 트리에서 그 위에 있는 가장 바깥쪽 스크립트(`zsh render_all.sh`, `python queue.py` 등) | **작업 체인**: 카드 한 장. 제목은 해당 스크립트의 첫 번째 주석 줄입니다 |
| 큐 스크립트의 명령줄에 있는 `scene:shot` 인자, 또는 [규칙](../ADAPTERS.md)으로 기술한 나만의 표기 방식 | **큐**: 어떤 샷이 완료됐고, 렌더링 중이며, 다음 순서인지 |
| `ffmpeg` 프로세스 | **인코딩**. `renderdock run`으로 시작했거나 출력이 로그 파일로 갈 때는 퍼센트와 남은 시간도 표시합니다 |
| 이 Mac에서 실행 중이고 큐에 프롬프트가 있는 ComfyUI 서버 | **ComfyUI** 작업: 어떤 프롬프트가 실행 중인지, 몇 개가 끝났고 몇 개가 대기 중인지. 퍼센트는 없습니다 |
| `caffeinate`로 감싸져 있고 아직 렌더링 프로세스가 없는 스크립트 | **대기 중** |
| `kill -STOP`으로 멈춘 프로세스 | **일시 정지** |
| 평소 프레임 시간의 10배(최소 5분) 동안 새 프레임이 없음 | **정체** |
| 출력 폴더의 이미지 파일(프레임 번호 기준으로 중복 제거) | **완료된 프레임 수**, 프레임당 초, 최신 프레임의 썸네일 |

출력 폴더는 Blender 자체의 `-o` / `--render-output`(`.blend` 기준 상대 경로인 `//` 포함) 또는 `--` 뒤에 오는 스크립트 인자 `--out DIR`에서 가져옵니다. 자신의 파이프라인에서 단순한 Blender 렌더링이 아닌 단계는 작은 [규칙 파일](../ADAPTERS.md)로 기술할 수 있습니다.

### 퍼센트의 출처

RenderDock은 전체 수를 알 때만 퍼센트를 표시합니다. 추측하지 않습니다.

| 출처 | 표시 방식 |
|---|---|
| 출력 폴더의 `render-progress.json`(아래 참고) | 정확한 값: `412/720 frames · 57%`와 남은 시간 |
| 명령줄의 프레임 범위: `-s 1 -e 250 -a` 또는 `-f 1..250` | 정확한 값 |
| 렌더 출력을 로그 파일로 리디렉션한 경우(`blender -b … > render.log`) | 정확한 값. 그 파일에 Blender가 직접 출력한 줄에서 읽습니다 |
| 다른 곳에 지정이 없을 때 `.blend`에 저장된 프레임 범위 | 정확한 값. 명령줄에 스크립트도 함께 넘기면 스크립트가 범위를 바꿀 수 있으므로 `≈`로 표시합니다. 압축 저장된 파일은 읽지 못합니다 |
| `renderdock run --`로 시작했거나 Blender 훅을 로드한 경우 | 정확한 값이며, 명령줄에 아무 정보가 없어도 마찬가지입니다. 완료된 작업과 실패한 작업도 구분합니다 |
| 출력 폴더 옆에 있는 같은 이름의 이전 클립 | 추정값이며 `≈`로 표시합니다. 프레임 수가 이를 넘어서면 바로 버립니다 |
| 위 항목이 모두 없음 | 프레임 수와 프레임당 초만 표시하며, 막대는 불확정 상태로 나타납니다 |

```bash
# 설정 없이 정확한 진행률
blender -b shot_010.blend -o //render/frame_#### -s 1 -e 250 -a
```

### `render-progress.json`: 어떤 파이프라인에서든 정확한 진행률

스크립트가 프레임을 직접 렌더링하거나, `.blend`가 압축 저장되어 있고 범위가 다른 어디에도 없다면, 프레임이 하나 끝날 때마다 출력 폴더에 작은 파일 하나를 쓰면 됩니다.

```json
{"done": 12, "total": 720}
```

```python
# Blender Python 스크립트 안에서
(out_dir / "render-progress.json").write_text(json.dumps({"done": i + 1, "total": len(frames)}))
```

파일을 쓸 수 있는 것이라면 무엇이든 이 방식으로 진행률을 알릴 수 있습니다. Blender에만 해당하는 것이 아닙니다.

## 하지 않는 것

- **렌더링에는 절대 손대지 않습니다**. 시그널을 보내지 않고, 렌더링 폴더에는 절대 쓰지 않습니다. 지켜보는 것 이상의 기능은 직접 켜기 전까지 모두 꺼져 있습니다. 알림 채널, 로컬 API(`127.0.0.1`만), 책상용 디스플레이를 위한 Bluetooth, 에이전트 요청에 답하기, 다른 프로그램을 위한 입구, MQTT가 그렇습니다. 알림 채널이나 MQTT 브로커를 추가하지 않는 한 네트워크 연결을 하지 않습니다.
- 일시 정지, 재개, 중지 버튼은 아직 없습니다. 큐 스크립트가 `STOP`/`CONT`를 직접 관리하는 경우가 많은데, 같은 스위치에 손이 둘 올라가는 것은 좋은 생각이 아닙니다.
- 출력 폴더와 프레임 범위가 모두 명령줄에 없어도 작업은 표시됩니다. CPU, 메모리, 경과 시간은 나오지만 프레임은 나오지 않습니다.
- SoC 온도는 IOHID 센서에서 읽습니다. 이는 Apple Silicon에서 쓸 수 있는 비공개 인터페이스입니다. Intel Mac이거나 시스템 업데이트로 센서가 옮겨진 경우, 해당 타일에는 `–`가 표시됩니다. 팬 속도와 소비 전력은 읽지 않습니다.
- M5 Max가 탑재된 Mac의 macOS 26에서 빌드하고 테스트했습니다. macOS 14용으로 컴파일은 되지만, 14와 15, 그리고 Intel Mac에서는 테스트하지 않았습니다. 제보를 환영합니다.
- UI 언어: 영어와 중국어 간체(시스템 언어를 따릅니다. `--lang en` 또는 `--lang zh`로 강제 지정할 수 있습니다).

## 로드맵

타임라인이 포함된 전체 TODO 목록은 **[ROADMAP.md](../../ROADMAP.md)** 문서에 있습니다.

요약하면 다음과 같습니다(계획이며, 약속은 아닙니다).

- 네트워크를 통한 접근: 토큰으로 보호되는 로컬 네트워크용 API, Wi-Fi로 연결되는 책상용 디스플레이
- 자체 진행률을 보여 주는 렌더러 추가
- 선택형 제어: 일시 정지, 재개, 우선순위 낮추기
- 서명 및 공증된 릴리스, Homebrew, 더 많은 UI 언어

## 개발

| 명령 | 설명 |
|---|---|
| `zsh scripts/build-app.sh` | `build/RenderDock.app`을 빌드합니다(ad-hoc 서명. 아이콘은 앱이 직접 그립니다) |
| `zsh scripts/install.sh [--login]` | 빌드하고 `/Applications`에 설치한 뒤 다시 실행합니다 |
| `swift run rd-checks` | 코어 부분을 검사합니다. 파싱, 이벤트, API, 알림, 에이전트, 장치 프로토콜이 대상입니다(검사 534개) |
| `.build/release/RenderDock --dump` | 감지된 작업과 지표를 UI 없이 텍스트로 출력합니다 |
| `.build/release/RenderDock --snapshot DIR [--demo]` | 캡슐과 패널을 PNG로 그려 냅니다 |
| `zsh scripts/make-demo.sh` | `assets/`의 스크린샷과 GIF를 다시 생성합니다 |
| `zsh scripts/fake-render.sh [프레임 수] [프레임당 초]` | 감지 기능을 테스트하기 위한 가짜 렌더링입니다 |
| `python3 scripts/verify-interactions.py <바이너리>` | `--debug`로 시작한 인스턴스에 클릭과 드래그를 주입해 펼치기, 접기, 달라붙기를 확인합니다(검사 12개) |

코드는 순수 Swift와 SwiftUI이며, 창에는 AppKit을 사용합니다. 약 9,000줄이고 패키지는 쓰지 않습니다. 자세한 내용은 [CONTRIBUTING.md](../../CONTRIBUTING.md)에 있습니다.

## 감사의 말

RenderDock은 아래 프로젝트들과 코드를 공유하지 않지만, 이들은 `sudo` 없이 무엇이 가능한지 보여 주었습니다. GPU와 센서 데이터를 읽는 방법은 [Stats](https://github.com/exelban/stats)와 [macmon](https://github.com/vladkens/macmon)이, 늘 곁에 있는 작은 UI를 Mac에 자연스럽게 녹여 내는 방법은 [boring.notch](https://github.com/TheBoredTeam/boring.notch)가 보여 주었습니다.

비슷한 목표를 가진 프로젝트로 [Blender Render Monitor](https://github.com/DUBSON0/blender-render-monitor)가 있습니다. 이 프로젝트도 Mac의 Blender 렌더링을 목록으로 보여 주며, 일시 정지와 재개, 큐를 이미 갖추고 있습니다. 진행률은 Blender 훅 스크립트나 로그 파일에서 가져옵니다. RenderDock 0.1은 이 프로젝트를 모르는 상태에서 작성되었으며, 둘은 코드를 공유하지 않습니다.

## 라이선스

[MIT](../../LICENSE)
