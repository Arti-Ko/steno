# Steno

Локальный аналог TurboScribe для macOS 26: расшифровка аудио и видео прямо на Mac, без облака.

**[⬇ Скачать Steno.dmg](https://github.com/Arti-Ko/steno/releases/latest/download/Steno.dmg)** · [все выпуски](https://github.com/Arti-Ko/steno/releases)

## Установка

1. Откройте `Steno.dmg` и перетащите Steno в «Программы».
2. Приложение не нотариально заверено Apple, поэтому при первом запуске macOS его остановит: **Системные настройки → Конфиденциальность и безопасность → «Всё равно открыть»**. Или в Терминале: `xattr -dr com.apple.quarantine /Applications/Steno.app`.
3. Нужен ffmpeg: `brew install ffmpeg`. Для ссылок — ещё `brew install yt-dlp`.

Требования: macOS 26 и Mac на Apple Silicon.

## Обновления

Steno сам проверяет [GitHub Releases](https://github.com/Arti-Ko/steno/releases) при запуске и каждые 6 часов. Когда выходит новая версия, появляется окно с описанием изменений: «Установить и перезапустить» скачивает архив, заменяет приложение и открывает новую версию. Проверить вручную — **Steno → Проверить обновления…**; выключить автопроверку — **Настройки → Обновления**.

## Что умеет

- **Импорт**: перетаскивание файлов (пакетно), ссылки YouTube / Dropbox / Google Drive через yt-dlp, запись с микрофона. Любые форматы, которые понимает ffmpeg.
- **Режимы**: Гепард (Whisper small), Дельфин (large-v3 turbo), Кит (large-v3). Модели скачиваются при первом запуске.
- **99 языков** с автоопределением.
- **Спикеры**: диаризация SpeakerKit (pyannote), авто или заданное число, переименование, объединение, переназначение реплик.
- **Восстановление звука**: шумоподавление и выравнивание громкости перед распознаванием.
- **Редактор**: текст синхронизирован с плеером, клик по реплике — переход, поиск ⌘F, правка текста, видео для mp4/mov.
- **Перевод**: системный Translation от Apple, на устройстве.
- **Экспорт**: DOCX, PDF, TXT, SRT, VTT, CSV, Markdown, JSON; настройки субтитров; пакетный экспорт.
- **Библиотека**: папки, поиск по названию и тексту, очередь с прогрессом, бейдж в Dock и уведомления.

Данные: `~/Library/Application Support/Steno/` (`Library/` — расшифровки, `Models/` — модели).

## Разработка

```sh
Scripts/build.sh              # dist/Steno.app
Scripts/build.sh --install    # в /Applications
Scripts/package.sh            # dist/Steno.dmg и dist/Steno.zip
swift test                    # юнит-тесты
STENO_AUDIO=~/audio.m4a STENO_MODE=cheetah swift test --filter EngineIntegration   # полный прогон
```

На машине с `safe.bareRepository=explicit` в глобальном git SwiftPM ломается — перед `swift` командами:
`export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all` (в скриптах уже есть).

## Выпуск версии

```sh
Scripts/release.sh 1.1.0
```

Скрипт обновляет `VERSION`, коммитит, ставит тег `v1.1.0` и пушит. GitHub Actions (`macos-26`) прогоняет тесты, собирает `Steno.dmg` и `Steno.zip` и публикует выпуск — установленные копии увидят его при следующей проверке.
