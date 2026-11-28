# PixelBone v0.8.1 — IK drag hotfix and visible chain controls

27 ноября 2026 · исправление пользовательских проблем, записанных в `pixelbone.tasks.json`.

## Что исправлено

1. **Move и Rotate при активном IK больше не получают `nil` вместо таблицы трансформаций.** В `pixrig/ui.lua` два участка получали результаты `rig:pose()` или `rig:assembledPose()` через конструкцию `condition and f() or g()`. В Lua она возвращала только первое значение функции, теряя второе (`T`). В обоих участках добавлены явные ветви `if/else`, сохраняющие оба результата. Это объясняет ошибки установленной v0.8.0 `main.lua:3944` (Move) и `main.lua:4297` (Rotate).
2. **Длина IK-цепочки на виду.** Во вкладке **Bone** в начале панели показывается `IK chain: N bones (1..8)` и расположены кнопки **Chain - / Chain +**. Они меняют выбранную IK-связку; если контроллера ещё нет, задают длину для следующего создаваемого контроллера. В блоке `IK controllers / chain length` остаются числовое поле длины и отдельное поле `IK influence %` — это две разные величины.
3. **Удалён старый Classic UI**, согласно новой задаче пользователя. Из расширения исключены команда `PixelBoneClassic` и модуль `pixrig/ui_classic.lua`. В ZIP исходников v0.8.1 этот модуль тоже не входит. Старую версию можно отдельно восстановить из прежнего архива v0.8.0.
4. **Убран временный файл** `pixrig/paint.lua.tmp` из исходников.

## Что оставлено без изменений

Файлы `pixrig/rig.lua`, `pixrig/binding.lua`, `pixrig/paint.lua`, `pixrig/export.lua`, `pixrig/skin.lua`, `pixrig/store.lua`, `pixrig/view.lua`, `pixrig/templates.lua`, `pixrig/json.lua` — без изменений относительно v0.8.0. Формат сохранения `sprite.data.pixrig version=2`, необязательное поле `assembly`, ключи Timeline, Auto Bone Binding, Paint Sheets и пользовательские слои не менялись.

## Проверки

- `texluac -p` для Lua-модулей, `entry.lua` и собранного `dist/main.lua`.
- `tests/test_rig.lua`, `test_templates.lua`, `test_assembly.lua`, `test_art_layers.lua`.
- `tests/harness_workspace.lua` (16 сценариев), включая реальные вызовы `onmousedown/onmousemove/onmouseup` для **Rotate/Move на костях под действием IK** и для Assembly. Тест проверяет изменение каналов, а не только отсутствие исключения. Сценарий также проверяет увеличение длины цепочки 2→3 и уменьшение 3→2.
- `tests/harness_bundle.lua`, `tests/harness_ui.lua` (отдельный запуск того же UI), `tests/harness_sizes.lua` при разрешениях 1366×768 и 1920×1080 с UI scale 100% и 200%.
- Убедились, что регистрация Classic-команды отсутствует и что установочное расширение содержит только `package.json` и собранный `main.lua`.

**Примечание:** автоматические проверки проводились в Lua и mock Aseprite API. Фактический запуск v0.8.1 в Aseprite 1.3-rc4-dev не выполнялся. В v0.8.0 пользователь действительно запускал расширение и сообщил об ошибках Move/Rotate с IK.

## Что проверить в настоящем Aseprite

1. Удалить/обновить прежнее расширение PixelBone v0.8.0 в `Edit → Preferences → Extensions`, установить `PixelBone_v0.8.1.aseprite-extension`, при необходимости перезапустить Aseprite.
2. Открыть копию проекта; создать соединённую цепочку руки/ноги и IK controller.
3. Во вкладке **Bone** попробовать **Chain - / Chain +**: количество костей меняется в диапазоне 1–8. Фактическая цепочка ограничена реальным числом соединённых предков.
4. В режимах **Animate** и **Assemble** попробовать **Move** и **Rotate** на кости под IK: в консоли не должно быть `nil T`.
5. Передвинуть IK-контроллер, проверить динамику конечности, несколько кадров, сохранение/перезапуск и экспорт на слои. Проверить существующий пайплайн `Paint Sheet → Assemble → Animate → редактирование Artwork`.
6. Убедиться, что в `File → Scripts` осталась одна команда PixelBone 0.8.1 без Classic UI.

## Известные особенности

- Если IK enabled и влияние 100%, итоговое вращение костей цепочки вычисляет IK; **обычное вращение FK на этих костях может не быть заметным** до уменьшения `IK influence %` или отключения IK. Для позирования конечности обычно следует передвигать кость-контроллер инструментом IK/Move. Исправление `nil T` не отменяет это поведение.
- Выбранное число IK chain — максимум. Если в скелете меньше соединённых костей, фактическая цепочка короче.
- IK с изначально разнесёнными `Disconnected`-деталями и независимая сборка суставов остаются отдельной задачей (PB-063).
- Встроенный карандаш для Paint Sheet не добавлялся: рисование выполняется в Aseprite.

## Изменённые/удалённые файлы

Изменено: `pixrig/ui.lua`, `entry.lua`, `build.py`, `package.json`, `tests/harness_workspace.lua`, `tests/harness_bundle.lua`, `tests/harness_ui.lua`, `tests/harness_sizes.lua`, `SOURCE_README.txt`, `PROJECT.md`.

Удалено: `pixrig/ui_classic.lua`, `tests/harness_classic.lua`, `pixrig/paint.lua.tmp`. Добавлен документ `RELEASE_0.8.1.md`.

Сборка: `python3 build.py`.
