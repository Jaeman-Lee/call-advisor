# Call Advisor for Termux

Android 통화 녹음 폴더에 새 파일이 완성되면 스마트폰 또는 사용자가 지정한 PC의
`whisper.cpp`로 한국어를 전사하고, ChatGPT 구독으로 로그인된 Codex CLI가
요약·합의사항·할 일을 정리합니다. 음성 전사에는 OpenAI API를 사용하지 않습니다.

결과 Markdown에는 Codex 분석 결과와 통화 전사 원문이 모두 들어갑니다. 전사 원문은
일반 텍스트 앱에서도 열 수 있도록 별도의 `.transcript.txt` 파일로도 저장합니다.
각 통화에는 Whisper 처리시간, 실시간 배율, 평균 사용 코어, CPU 총시간, 최대
메모리와 Codex 처리시간이 함께 기록됩니다.

통화마다 기계 판독 가능한 `.metrics.csv`도 생성됩니다. `CODEX_ENABLED=false`로
설정하면 전사 텍스트도 외부로 보내지 않는 완전 로컬 모드로 동작합니다.

Silero VAD가 전사 전에 발화 구간을 검출해 무음 구간을 Whisper 입력에서 제외합니다.
로컬 CPU-only 전사의 최소·권장 자원을 비교하는 방법은
[CPU-only 로컬 음성 전사 평가](docs/LOCAL_INFERENCE.md)를 참고하세요.

## 구조

```text
통화 종료 → Recordings/Call에 녹음 완료
                    ↓ inotify
              FFmpeg 16 kHz 변환
                    ↓
    PC medium Q5_0 우선 ── 실패 시 폰 base
                    ↓
             Codex 전사문 분석
                    ↓
       Markdown 저장 + 요약 알림 + 결과 열기
```

## 설치

```sh
pkg install git cmake make clang ffmpeg inotify-tools termux-api time
./setup-whisper.sh base
cp call-advisor.conf.example call-advisor.conf
./call-advisor.sh check
./call-advisor.sh watch
```

스마트폰에서만 처리하는 마지막 고정판은 GitHub Release `v0.1.0-local`입니다.
PC `small` 기본판은 `v0.2.0`에 보존되어 있습니다.
최신판도 `TRANSCRIBE_BACKEND=local`로 설정하면 같은 보안 경계로 동작합니다.

## PC 원격 전사

PC에 `whisper.cpp`, `medium Q5_0` 모델과 Silero VAD 모델을 준비하고 SSH 공개키 인증을
설정합니다. 실제 PC 주소와 개인 키 경로는 Git에 포함되지 않는
`call-advisor.conf`에만 기록합니다.

```sh
TRANSCRIBE_BACKEND=auto
LOCAL_FALLBACK=true
REMOTE_SSH_HOST='user@pc-tailscale-name'
REMOTE_SSH_PORT=22
REMOTE_SSH_KEY="$HOME/.ssh/id_ed25519"
REMOTE_DIR='whisper-server'
REMOTE_MODEL='models/ggml-medium-q5_0.bin'
REMOTE_VAD_MODEL='models/ggml-silero-v6.2.0.bin'
REMOTE_THREADS=6
```

`auto`는 PC를 우선 사용하고 연결 또는 원격 전사가 실패하면 스마트폰 base로
복귀합니다. SSH 연결은 60초 동안 재사용해 짧은 파일의 인증 지연을 줄입니다.
스마트폰은 16 kHz WAV를 암호화된 SSH 연결로 보내고, 전사문과 성능 지표를 받은 뒤
PC의 임시 WAV·전사문·지표를 삭제합니다. 결과 Markdown과 CSV에는 사용 백엔드와
왕복 전송 시간이 기록됩니다.

```sh
./call-advisor.sh check
```

이 명령으로 PC 실행 파일, 모델 및 fallback 상태까지 확인할 수 있습니다.
구성, 보안 경계와 스마트폰·PC 실측은
[PC 원격 음성 전사](docs/REMOTE_INFERENCE.md)를 참고하세요.
13개 음성에서의 base 대비 품질·자원 비교는
[모델 평가](docs/MODEL_EVALUATION.md)를 참고하세요.

기본 감시 경로는 Samsung 계열 기기에서 사용하는
`/storage/emulated/0/Recordings/Call`입니다. 결과는 파일 앱에서 쉽게 찾도록 같은
`Recordings` 아래의 `/storage/emulated/0/Recordings/CallAnalysis`에 저장됩니다.

## Obsidian 연동

Obsidian Android는 임의의 Markdown 파일을 연결 앱으로 열지 않을 수 있습니다.
설정에 Vault 경로와 이름을 지정하면 결과를 Vault에도 복사하고, 완료 알림은
`obsidian://` 링크로 노트를 직접 엽니다.

```sh
OBSIDIAN_VAULT_DIR='/storage/emulated/0/Obsidians/MyVault'
OBSIDIAN_VAULT_NAME='MyVault'
OBSIDIAN_FOLDER='CallAnalysis'
```

`base` 모델로 먼저 시험한 뒤 한국어 고유명사 정확도가 부족하면
`./setup-whisper.sh small`을 실행하고 설정의 모델 경로를 `ggml-small.bin`으로
바꿀 수 있습니다. `small`은 다운로드와 전사 시간, 저장공간 사용량이 더 큽니다.

## 개인정보와 법적 주의

- 통화 녹음 및 상대방 고지 의무는 국가·지역과 상황에 따라 다릅니다.
- 자동 전사에는 오류가 있을 수 있으므로 이름, 전화번호, 금액, 날짜를 확인하세요.
- 이 프로젝트는 원본 녹음을 삭제하거나 이동하지 않습니다.
- 원본, 전사문, 분석 결과와 로컬 설정은 Git에 커밋하지 마세요.
- 개인용 ChatGPT/Codex 데이터 제어 설정도 확인하세요.
