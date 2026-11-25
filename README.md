# 잇칸 (EATKAN)

냉장고·냉동실·팬트리의 식재료를 관리하는 Flutter 기반 Android 앱입니다. 재료를 구매한 묶음별로 수량과 날짜를 기록하고, 요리에 사용한 양과 장보기에서 실제로 입고한 양을 재고에 반영합니다. 팀 프로젝트 멘토링 제출용 소스입니다.

## 실행

개발 환경은 Flutter 3.47.2, Dart 3.13.2, Android SDK 36입니다. Android 7.0(API 24) 이상 기기 또는 에뮬레이터를 연결한 뒤 저장소 루트에서 실행합니다.

```sh
flutter pub get --enforce-lockfile
flutter devices
flutter run
```

여러 기기가 연결되어 있으면 `flutter run -d <기기 ID>`로 선택합니다. 첫 화면에서 샘플 주방을 열거나 **내 재료 등록부터 시작**을 눌러 직접 입력할 수 있습니다. 기본 시연에는 API 키가 필요하지 않습니다.

## 시연 흐름

1. **재고 등록**에서 이름·수량·위치를 직접 입력하거나 한국어 영수증 사진에서 인식한 품목을 확인해 입고합니다.
2. **AI 요리**에서 예시 레시피를 열고 조리 단계를 진행합니다. 조리 완료 화면에서 실제로 사용한 묶음과 양을 확인하면 재고가 갱신됩니다.
3. **장보기**에서 부족한 재료를 확인하거나 항목을 직접 추가합니다. 쇼핑몰 검색은 쿠팡·네이버쇼핑·컬리로 연결됩니다. 물건을 받은 뒤 입고를 확정하면 재고에 반영됩니다.

## 코드와 검증

앱은 `lib/`, Android 연동은 `android/`, 회귀 테스트는 `test/`에 있습니다. 로컬 AI 중계와 관련 테스트는 `tool/`에 있습니다.

```sh
flutter analyze
flutter test
node --test tool/local_ai_proxy.test.mjs
```

Node.js 24는 로컬 AI 중계와 해당 테스트에 사용합니다. 릴리스 APK 빌드와 서명 방법은 [Android 릴리스 안내](android/RELEASE.md)에 있습니다.

## 선택 기능인 온라인 AI 연결

온라인 추천과 대화 해석을 사용하려면 개발 PC에 `config/ai.example.json`을 `config/ai.local.json`으로 복사합니다. `AI_BASE_URL`에 `https://api.openai.com/v1/responses`, `AI_API_FORMAT`에 `response`를 입력하고, `AI_MODEL`과 `AI_API_KEY`는 사용할 계정의 값으로 설정합니다. 제공자 키는 PC의 중계 프로세스에서 읽습니다.

- macOS에서는 Android 기기를 연결하고 `sh tools/run_ai_local.sh`를 실행합니다.
- Windows PowerShell에서는 Android 기기를 연결하고 `.\tools\run_ai_local.ps1`을 실행합니다.

온라인 기능을 요청하면 해당 기능에 필요한 질문과 재료 정보가 제공자에게 전송되며 계정의 API 사용량이 발생할 수 있습니다.
