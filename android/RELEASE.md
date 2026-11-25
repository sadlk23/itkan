# Android 실행과 배포 서명

다음 명령은 저장소 루트에서 실행합니다.

## 에뮬레이터·학부 시연

일반 시연은 `flutter run -d emulator-5554`로 실행합니다. 릴리스 모드로 같은 에뮬레이터에 설치할 때는 로컬 디버그 키 사용을 명시합니다.

```sh
ITKAN_LOCAL_RELEASE=true flutter run --release -d emulator-5554
```

PowerShell에서는 다음과 같이 명령에 필요한 동안 설정합니다.

```powershell
$env:ITKAN_LOCAL_RELEASE = 'true'
try { flutter run --release -d emulator-5554 }
finally { Remove-Item Env:ITKAN_LOCAL_RELEASE }
```

## 배포용 APK 또는 앱 번들

`flutter build apk --release`는 업로드 서명 설정이 없으면 서명 전 APK를 생성합니다. Android에 설치하거나 스토어에 제출할 파일에는 서명이 필요합니다.

업로드 키를 관리하는 담당자가 `storeFile`, `storePassword`, `keyAlias`, `keyPassword`를 담은 비공개 Java properties 파일을 준비합니다. `storeFile`은 키 저장소의 절대 경로 또는 properties 파일 기준 상대 경로입니다. `ITKAN_SIGNING_PROPERTIES`로 파일을 지정할 수 있고, 기본 탐색 위치는 Git에서 제외된 `android/key.properties`입니다.

```sh
ITKAN_SIGNING_PROPERTIES="$HOME/.config/itkan/android-upload.properties" flutter build appbundle --release
```

배포 빌드에서는 `ITKAN_LOCAL_RELEASE`를 해제합니다. 빌드한 APK는 Android SDK의 `apksigner verify --print-certs`로 확인하고, 앱 번들은 `keytool -printcert -jarfile`로 등록된 업로드 인증서 지문과 대조합니다.
