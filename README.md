# VK TV

Open-source клиент для просмотра видео VK на Android TV.

## Стек

- Flutter 3.22 + Dart 3
- media_kit (libmpv) — воспроизведение HLS/MP4
- Riverpod — state management
- go_router — навигация

## Сборка локально

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter build apk --debug
```

## Сборка через GitHub Actions

Каждый пуш в `main` автоматически собирает APK.
Артефакты доступны во вкладке **Actions → последний workflow run → Artifacts**.

Для релизной сборки с подписью добавь в Settings → Secrets:
- `KEY_STORE_PASSWORD`
- `KEY_PASSWORD`
- `KEY_ALIAS`
- `KEY_PATH`

И раскомментируй блок `env:` в `build.yml`.

## Структура

```
lib/
├── core/          # DI, роутер
├── domain/        # Entities, use cases, интерфейсы репозиториев
├── data/          # VkExtractor, реализации репозиториев
└── presentation/  # Экраны, виджеты, провайдеры
```

## VkExtractor

Алгоритм извлечения стрима:
1. GET страницы с User-Agent мобильного браузера
2. Парсинг `playerParams` из inline JS
3. Парсинг JSON с ключами `hls`, `url1080`, `url720`...
4. Fallback: regexp на `.m3u8` / `.mp4`

Приоритет: HLS (адаптивный битрейт) > 1080p > 720p > 480p

## TODO

- [ ] Авторизация через WebView + сохранение cookie
- [ ] VK Video API для ленты и поиска
- [ ] История просмотров (Hive)
- [ ] Субтитры
- [ ] Выбор качества в плеере
