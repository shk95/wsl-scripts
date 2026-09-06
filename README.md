# wsl-scripts

Windows 쪽에서 실행하는 PowerShell 스크립트 모음. WSL 안의 이 폴더는 Windows에서
`\\wsl.localhost\Ubuntu26.04\home\user1\wsl-scripts\` 로 보인다.
관리자 PowerShell에서 실행할 때:

```powershell
Set-Location \\wsl.localhost\Ubuntu26.04\home\user1\wsl-scripts
powershell -ExecutionPolicy Bypass -File .\WSL-KeepAlive.ps1 -Action Status
```

| 파일 | 역할 |
|---|---|
| `WSL-KeepAlive.ps1` | KeepAlive 태스크 설치/제거/활성/비활성/일시정지/재개/상태. `-Distro` 로 배포판 지정 |
| `keepalive-loop.ps1` | 태스크가 실행하는 루프 본체. Install 시 `C:\ProgramData\WSL-KeepAlive\` 로 복사됨 |
| `Check-WslPackage.ps1` | WSL 엔진이 Store(자동 업데이트) / MSI(수동) 인지, 배포판이 Store 앱인지 import 인지 판정 |
| `WSL-PowerGuard.ps1` | 절전 방지 전원 구성표 Enable / Restore / Status. 노트북은 덮개 동작·배터리 옵션 |
| `Compact-WslDistro.ps1` | 배포판 vhdx 압축: Status / Trim / Compact / SetSparse. fstrim → 종료 → Optimize-VHD 또는 diskpart |

## KeepAlive 운용

```powershell
.\WSL-KeepAlive.ps1 -Action Install -Distro Ubuntu26.04     # 태스크 등록(기존 태스크 교체), 실행 계정 프롬프트
.\WSL-KeepAlive.ps1 -Action Pause   -Distro Ubuntu26.04 -Shutdown   # 지금 내리고 Resume 전까지 안 띄움 (관리자 불필요)
.\WSL-KeepAlive.ps1 -Action Resume  -Distro Ubuntu26.04     # 10초 안에 다시 뜸
.\WSL-KeepAlive.ps1 -Action Disable -Distro Ubuntu26.04 -Shutdown   # 태스크 자체를 끔 (재부팅해도 안 뜸)
.\WSL-KeepAlive.ps1 -Action Enable  -Distro Ubuntu26.04
.\WSL-KeepAlive.ps1 -Action Uninstall -Distro Ubuntu26.04
```

일시정지 플래그 파일은 `C:\ProgramData\WSL-KeepAlive\flags\paused` (flags 폴더만 일반 사용자 쓰기 가능), 루프 로그는 같은 폴더의
`keepalive-<배포판>.log` (VM이 언제 내려갔는지 exit code 와 함께 기록).

## PowerGuard 운용

```powershell
.\WSL-PowerGuard.ps1 -Action Status
.\WSL-PowerGuard.ps1 -Action Enable                                   # 데스크톱: AC 절전/최대절전/디스크 끄기 해제
.\WSL-PowerGuard.ps1 -Action Enable -Laptop -LidAction DoNothing      # 노트북: AC 에서 덮개 닫아도 유지, 배터리 정책은 원본 유지
.\WSL-PowerGuard.ps1 -Action Enable -Laptop -KeepAwakeOnBattery       # 배터리에서도 유지 (소모 주의)
.\WSL-PowerGuard.ps1 -Action Restore                                  # 백업된 원래 구성표로 복구
```

Enable 은 원본 구성표를 `C:\ProgramData\WSL-PowerGuard\original-scheme.pow` 로 export 한 뒤
복제본 "WSL KeepAwake" 를 만들어 거기에만 변경을 가한다. Restore 는 원본을 다시 활성화하고 복제본을 지운다.

## vhdx 압축 운용

```powershell
.\Compact-WslDistro.ps1 -Action Status  -Distro Ubuntu26.04          # 회수 예상량, sparse 여부, 방법 확인 (관리자 불필요)
.\Compact-WslDistro.ps1 -Action Compact -Distro Ubuntu26.04 -WhatIf  # 실제 변경 없이 절차만 확인
.\Compact-WslDistro.ps1 -Action Compact -Distro Ubuntu26.04 -Restart # fstrim → wsl -t → 압축 → 재시작
.\Compact-WslDistro.ps1 -Action SetSparse -Distro Ubuntu26.04 -Sparse $true   # 이후엔 fstrim+종료만으로 자동 회수
```

- fstrim 은 압축 직전에 항상 실행한다(생략: `-SkipTrim`). 게스트가 discard 로 표시한 블록만 압축이 회수한다.
- Windows 10/11 차이는 없다. `Optimize-VHD` 유무(Hyper-V 모듈)와 WSL 버전(sparse 지원)만 영향을 준다.
- sparse 모드 vhdx 는 압축 대상이 아니다. fstrim + 배포판 종료로 자동 회수되며, 스크립트도 `-Force` 없이는 건너뛴다.
- KeepAlive 태스크가 설치되어 있으면 압축 중 자동으로 일시정지 플래그를 만들고 끝나면 지운다.

## 테스트 메모

이 스크립트들을 WSL 안에서 띄운 Windows 프로세스로 `\\wsl.localhost\...` 경로에서 직접 실행하면 wsl.exe 호출에서 멈추는 경우가 있다.
Windows 쪽 콘솔에서 실행하거나, 로컬 디스크(예: `C:\Tools\wsl-scripts`)로 복사해 실행한다.
