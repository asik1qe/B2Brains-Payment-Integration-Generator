# Provider Compiler

Provider Compiler преобразует OpenAPI 3.0.x спецификацию платежного провайдера в интеграцию для Space Payments.

Основной процесс:

```text
OpenAPI -> parsing -> semantic mapping -> review/overrides -> generation -> verification
```

На вход подается OpenAPI спецификация провайдера в YAML или JSON. На выходе при успешной генерации создаются:

- `<provider>_service.rb` - реализация сервиса провайдера;
- `INTEGRATION.md` - описание найденного маппинга, авторизации, статусов, ошибок и особенностей интеграции;
- `fixtures.json` - тестовые данные для проверки сгенерированной интеграции.

CLI не выполняет реальную выплату. Он анализирует спецификацию, строит интеграционный сервис и проверяет сгенерированные артефакты.

Если критичная часть спецификации неоднозначна, Provider Compiler не выбирает вариант автоматически. В интерактивном режиме CLI показывает найденные варианты, позволяет выбрать нужный и сохраняет решение в overrides.

## 1. Быстрый старт

Требуются Ruby и Bundler.

Из корня проекта установить зависимости:

```powershell
bundle install
```

Проверить CLI:

```powershell
bundle exec ruby bin/integrate --help
```

Самая короткая проверка на готовой спецификации NovaPay:

```powershell
bundle exec ruby bin/integrate `
  --spec .\judge_cases\providers\01_novapay_official.yaml `
  --provider novapay_demo `
  --output .\tmp\novapay_demo
```

При успешном запуске в терминале будут пройдены пять этапов:

```text
[1/5] OpenAPI       OK
[2/5] Mapping       OK
[3/5] Review        not required / resolved
[4/5] Generation    OK
[5/5] Verification  OK

Status: SUCCESS
```

После этого в `tmp\novapay_demo` должны появиться три файла:

```text
novapay_demo_service.rb
INTEGRATION.md
fixtures.json
```

## 2. Как использовать со своей OpenAPI спецификацией

Минимальная команда:

```powershell
bundle exec ruby bin/integrate `
  --spec .\path\provider_api.yaml `
  --provider my_provider `
  --output .\output\my_provider
```

Параметры CLI:

| Параметр | Назначение |
|---|---|
| `--spec PATH` | Путь к OpenAPI YAML или JSON файлу |
| `--provider NAME` | Имя провайдера, используется при генерации имени файла и класса |
| `--output DIR` | Каталог для результата. По умолчанию `./output` |
| `--overrides PATH` | YAML файл с ручными решениями для неоднозначного mapping |
| `--config PATH` | YAML файл конфигурации запуска |
| `--debug` | Подробные diagnostics и дополнительные сведения о mapping |
| `--non-interactive` | Не задавать вопросы. Если требуется решение пользователя, вернуть `NEEDS REVIEW` |
| `--force` | Перезаписать уже существующие сгенерированные файлы без вопроса |
| `-h`, `--help` | Показать справку |

Для первого ручного запуска обычно достаточно только `--spec`, `--provider` и `--output`.

## 3. Что происходит во время запуска

### OpenAPI

CLI читает YAML или JSON, проверяет версию OpenAPI и преобразует документ во внутреннюю модель.

Если файл поврежден или не соответствует поддерживаемому формату, генерация не начинается.

### Mapping

Compiler ищет операции и поля, необходимые контракту Space Payments:

- создание выплаты;
- проверка статуса;
- обработка callback;
- идентификаторы операции;
- сумма;
- платежные реквизиты;
- статусы;
- ошибки;
- авторизация.

Для каждого решения сохраняются основания mapping и уровень уверенности.

### Review

Если критичный mapping нельзя определить однозначно, CLI переходит к review.

Пример поведения:

```text
REVIEW 1/1 - create_request

The endpoint could not be selected unambiguously.

Candidates:
  [1] POST /payouts
  [2] POST /transfers

Choose:
  1-2  select
  m    manual endpoint
  q    abort
```

После выбора решение сохраняется в YAML overrides, затем mapping запускается повторно уже с учетом решения пользователя.

Если `--overrides` не указан, для интерактивных решений используется файл:

```text
.provider-compiler/<provider>.overrides.yml
```

Например:

```text
.provider-compiler/polaris_judge.overrides.yml
```

При следующих запусках сохраненный override будет найден автоматически для того же имени провайдера.

### Generation

После разрешения обязательных mapping-решений создаются:

```text
<provider>_service.rb
INTEGRATION.md
fixtures.json
```

### Verification

Сразу после генерации Compiler проверяет результат. В отчете отображаются:

```text
Verification:
  syntax: passed
  fixtures: passed
  contract: passed
  scenarios: passed
```

То есть отдельную команду verify после генерации запускать не требуется.

## 4. Интерактивный и автоматический режимы

### Интерактивный режим

Это основной режим для работы с новой или неоднозначной спецификацией.

Запуск:

```powershell
bundle exec ruby bin/integrate `
  --spec .\provider.yaml `
  --provider provider_name `
  --output .\output\provider_name
```

Если требуется решение, CLI покажет варианты и предложит выбрать один из них.

### Автоматический режим

Используется для CI, regression tests и массовых проверок:

```powershell
bundle exec ruby bin/integrate `
  --spec .\provider.yaml `
  --provider provider_name `
  --output .\output\provider_name `
  --non-interactive
```

В этом режиме CLI никогда не спрашивает пользователя. Если продолжение без ручного решения небезопасно, результат будет:

```text
Status: NEEDS REVIEW
```

`judge_cases\run_all.rb` специально использует `--non-interactive`, потому что это автоматическая regression-матрица. Для демонстрации ручного review нужно запускать конкретный сценарий отдельно без этого параметра.

## 5. Работа с overrides

Overrides нужны только там, где OpenAPI не дает достаточно информации для безопасного автоматического решения или где пользователь хочет явно зафиксировать mapping.

Пример запуска с готовым override:

```powershell
bundle exec ruby bin/integrate `
  --spec .\judge_cases\providers\03_atlasbank_basic_review.yaml `
  --provider atlasbank_judge `
  --overrides .\judge_cases\overrides\atlasbank.yml `
  --output .\tmp\judge_demo\atlasbank
```

Чтобы увидеть review до применения готового файла, запустить тот же сценарий без `--overrides`:

```powershell
bundle exec ruby bin/integrate `
  --spec .\judge_cases\providers\03_atlasbank_basic_review.yaml `
  --provider atlasbank_manual_demo `
  --output .\tmp\judge_demo\atlasbank_manual
```

Для отдельной демонстрации неоднозначного выбора операции можно использовать Polaris:

```powershell
bundle exec ruby bin/integrate `
  --spec .\judge_cases\providers\07_polaris_ambiguous_operations.yaml `
  --provider polaris_manual_demo `
  --output .\tmp\judge_demo\polaris_manual
```

Здесь важно использовать новое имя `--provider`, если ранее для этого имени уже был сохранен файл `.provider-compiler/<provider>.overrides.yml`.

Пример общей структуры override находится в:

```text
config/overrides.example.yml
```

## 6. Повторный запуск и перезапись результата

Если в `--output` уже находятся сгенерированные файлы, интерактивный CLI спросит разрешение на перезапись.

Для автоматической перезаписи:

```powershell
bundle exec ruby bin/integrate `
  --spec .\provider.yaml `
  --provider provider_name `
  --output .\output\provider_name `
  --force
```

В non-interactive режиме существующий output без `--force` считается ошибкой использования.

## 7. Конфигурация через YAML

Вместо длинной команды можно создать в корне проекта файл `provider-compiler.yml`:

```yaml
spec: ./provider_api.yaml
provider: my_provider
output: ./output/my_provider
overrides: ./my_provider_overrides.yml
debug: false
```

После этого:

```powershell
bundle exec ruby bin/integrate
```

Файл `provider-compiler.yml` подхватывается автоматически.

Можно указать другой файл:

```powershell
bundle exec ruby bin/integrate --config .\configs\provider.yml
```

Параметры, переданные непосредственно в CLI, имеют приоритет над значениями из конфигурации.

## 8. Что означает результат CLI

| Статус | Exit code | Значение |
|---|---:|---|
| `SUCCESS` | `0` | Mapping разрешен, файлы созданы, verification завершен успешно |
| `FAILED` | `1` | Обнаружена ошибка, при которой pipeline не может безопасно продолжить работу |
| usage error | `2` | Неверные параметры запуска, отсутствующий файл, конфликт output и т.п. |
| `NEEDS REVIEW` | `3` | В non-interactive режиме найдено решение, требующее участия пользователя |

Для Windows PowerShell exit code последней команды можно посмотреть так:

```powershell
$LASTEXITCODE
```

## 9. Поддерживаемый вход

Текущая гарантированная область поддержки:

- OpenAPI `3.0.x`;
- YAML и JSON;
- JSON request/response content;
- локальные `$ref` внутри документа;
- API Key;
- HTTP Bearer;
- HTTP Basic;
- request и response schemas;
- path, query и header parameters;
- nested objects;
- enum;
- date-time;
- money transformations;
- status mapping;
- error mapping;
- callback/webhook mapping;
- ручные overrides для неоднозначных решений.

Ограничения, которые важно учитывать:

- OpenAPI 3.1.x не поддерживается как гарантированный формат;
- внешние `$ref` не поддерживаются;
- `oneOf`, `anyOf`, `allOf`, `not` требуют review;
- content без JSON требует review;
- неподдерживаемые security scheme types требуют review;
- path-level и operation-level `servers` требуют review;


## 10. Полный запуск автоматических тестов

Запуск всей тестовой базы:

```powershell
bundle exec rspec
```

В конце выводится общий отчет:

```text
PROVIDER COMPILER TEST REPORT

UNIT
PIPELINE
ACCEPTANCE
REAL-WORLD OPENAPI
TOTAL

RESULT: PASS
```

Количество examples берется из текущего набора тестов и отображается автоматически.

То же самое через Rake:

```powershell
bundle exec rake test
```

Группы отдельно:

```powershell
bundle exec rake spec:unit
bundle exec rake spec:pipeline
bundle exec rake spec:acceptance
bundle exec rake spec:real_world
```

## 11. Готовая regression-матрица

Запустить все подготовленные сценарии одной командой:

```powershell
.\judge_cases\run_all.ps1
```

Альтернативно:

```powershell
bundle exec ruby .\judge_cases\run_all.rb
```

или через Rake:

```powershell
bundle exec rake judge
```

Этот запуск проверяет не только успешные случаи. Для части входных данных правильным результатом является `FAILED` или `NEEDS REVIEW`.

Ожидаемая матрица:

| Сценарий | Что проверяется | Ожидаемый результат |
|---|---|---|
| NovaPay | Полный основной pipeline | `SUCCESS`, 3 файла |
| RiverPay | Bearer, query status, nested response | `SUCCESS`, 3 файла |
| AtlasBank | Basic auth и заранее подготовленный override | `SUCCESS`, 3 файла |
| PulseMoney | API key в query, webhook metadata | `SUCCESS`, 3 файла |
| Meridian | Глубоко вложенные request, response и callback | `SUCCESS`, 3 файла |
| Northstar | Нет обязательного callback | `FAILED`, 0 файлов |
| Polaris | Неоднозначный create endpoint в non-interactive режиме | `NEEDS REVIEW`, 0 файлов |
| Broken YAML | Ошибка парсинга | `FAILED`, 0 файлов |
| PayPal public excerpt | Реальная публичная структура без callback Space Payments | `FAILED`, 0 файлов |
| Stripe public excerpt | Реальная публичная структура без callback Space Payments | `FAILED`, 0 файлов |
| SumUp public excerpt | Реальная публичная структура без callback Space Payments | `FAILED`, 0 файлов |

Результаты regression-матрицы записываются в:

```text
tmp/judge_cases
```

Источники публичных OpenAPI excerpt-файлов зафиксированы отдельно:

```text
judge_cases/sources/paypal_payouts_v1_snapshot.source.yml
judge_cases/sources/stripe_payouts_snapshot.source.yml
judge_cases/sources/sumup_payouts_snapshot.source.yml
```

## 12. Проверка сценариев по одному

### NovaPay

Основной успешный сценарий:

```powershell
bundle exec ruby bin/integrate --spec .\judge_cases\providers\01_novapay_official.yaml --provider novapay_judge --output .\tmp\judge_demo\novapay
```

Ожидается `SUCCESS` и три сгенерированных файла.

### RiverPay

Bearer authentication, query parameter для проверки статуса, вложенный response:

```powershell
bundle exec ruby bin/integrate --spec .\judge_cases\providers\02_riverpay_bearer_query_nested.yaml --provider riverpay_judge --output .\tmp\judge_demo\riverpay
```

Ожидается `SUCCESS`.

### AtlasBank

Запуск с подготовленным override:

```powershell
bundle exec ruby bin/integrate --spec .\judge_cases\providers\03_atlasbank_basic_review.yaml --provider atlasbank_judge --overrides .\judge_cases\overrides\atlasbank.yml --output .\tmp\judge_demo\atlasbank
```

Ожидается `SUCCESS`.

Для демонстрации review запускать без `--overrides` и с новым именем provider.

### PulseMoney

API key в query и webhook metadata:

```powershell
bundle exec ruby bin/integrate --spec .\judge_cases\providers\04_pulsemoney_query_apikey.yaml --provider pulsemoney_judge --output .\tmp\judge_demo\pulsemoney
```

Ожидается `SUCCESS`.

### Meridian

Вложенные request, response и callback структуры:

```powershell
bundle exec ruby bin/integrate --spec .\judge_cases\providers\05_meridian_nested_objects.yaml --provider meridian_judge --output .\tmp\judge_demo\meridian
```

Ожидается `SUCCESS`.

### Northstar

В спецификации отсутствует обязательный callback:

```powershell
bundle exec ruby bin/integrate --spec .\judge_cases\providers\06_northstar_missing_callback.yaml --provider northstar_judge --output .\tmp\judge_demo\northstar
```

Правильный результат: `FAILED`. Generation не должна начинаться, файлы не должны создаваться.

### Polaris

Неоднозначный выбор операции:

```powershell
bundle exec ruby bin/integrate --spec .\judge_cases\providers\07_polaris_ambiguous_operations.yaml --provider polaris_manual_demo --output .\tmp\judge_demo\polaris
```

В интерактивном терминале CLI должен показать варианты и предложить выбрать endpoint.

Автоматическая проверка того же поведения:

```powershell
bundle exec ruby bin/integrate --spec .\judge_cases\providers\07_polaris_ambiguous_operations.yaml --provider polaris_non_interactive_demo --output .\tmp\judge_demo\polaris_non_interactive --non-interactive
```

Правильный результат: `NEEDS REVIEW`, exit code `3`, 0 файлов.

### Поврежденный YAML

```powershell
bundle exec ruby bin/integrate --spec .\judge_cases\providers\08_broken_yaml.yaml --provider malformed_judge --output .\tmp\judge_demo\malformed
```

Правильный результат: `FAILED`, ошибка `openapi_parse_error`, generation не начинается.

### PayPal Payouts public excerpt

```powershell
bundle exec ruby bin/integrate --spec .\judge_cases\providers\09_paypal_payouts_public_snapshot.json --provider paypal_public_judge --output .\tmp\judge_demo\paypal
```

Спецификация основана на публичном OpenAPI PayPal. В выбранном excerpt нет callback, обязательного для контракта Space Payments, поэтому правильный результат: безопасный `FAILED` до generation.

### Stripe Payouts public excerpt

```powershell
bundle exec ruby bin/integrate --spec .\judge_cases\providers\10_stripe_payouts_public_snapshot.yaml --provider stripe_public_judge --output .\tmp\judge_demo\stripe
```

Правильный результат для подготовленного excerpt: `FAILED` до generation из-за отсутствия обязательного callback.

### SumUp Payouts public excerpt

```powershell
bundle exec ruby bin/integrate --spec .\judge_cases\providers\11_sumup_payouts_public_snapshot.yaml --provider sumup_public_judge --output .\tmp\judge_demo\sumup
```

Правильный результат для подготовленного excerpt: `FAILED` до generation из-за отсутствия обязательного callback.

## 13. Как понять, что продукт работает корректно

Для быстрой проверки достаточно выполнить три действия:

```powershell
bundle install
bundle exec rspec
.\judge_cases\run_all.ps1
```

После этого:

1. общий RSpec отчет должен завершиться `RESULT: PASS`;
2. judge matrix должна показать все сценарии как `PASS`, включая ожидаемые безопасные отказы;
3. ручной NovaPay запуск должен завершиться `Status: SUCCESS` и создать три файла;
4. ручной Polaris запуск должен показать интерактивный review;
5. Northstar должен остановиться до generation и не создать артефакты.

Эти проверки покрывают unit-логику, полный compiler pipeline, generated runtime, CLI, универсальность на разных структурах и безопасное поведение на неполных или неоднозначных входных данных.

## 14. Дополнительная документация

Документация по классам и модулям находится в папке:

```text
docs
```

Структура `docs` повторяет структуру production-кода.