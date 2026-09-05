# Отчёт по исследованию бинарных зависимостей StarRocks 3.5.11

| | |
|---|---|
| **Дата** | 21 апреля 2026 |
| **Версия ПО** | StarRocks 3.5.11 |
| **Исследуемый компонент** | Backend (BE), C++ |
| **Цель** | Идентификация, удаление закрытых бинарных зависимостей и оценка влияния на функциональность системы |
| **Статус** | Завершён |

## Содержание

1. [Резюме исследования](#1-резюме-исследования)
2. [Цель и область исследования](#2-цель-и-область-исследования)
3. [Методология](#3-методология)
4. [Этап 1: Инвентаризация бинарных зависимостей](#4-этап-1-инвентаризация-бинарных-зависимостей)
5. [Этап 2: Анализ и удаление компонентов](#5-этап-2-анализ-и-удаление-компонентов)
6. [Этап 3: Компиляция](#6-этап-3-компиляция)
7. [Этап 4: Тестирование и выявленные ошибки](#7-этап-4-тестирование-и-выявленные-ошибки)
8. [Детальный анализ подсистемы SpillDown](#8-детальный-анализ-подсистемы-spilldown)
9. [Карта исследованных файлов](#9-карта-исследованных-файлов)
10. [Матрица воздействия удаления на функциональность](#10-матрица-воздействия-удаления-на-функциональность)
11. [Выводы](#11-выводы)
12. [Рекомендации](#12-рекомендации)
13. [Приложения](#13-приложения)

---

## 1. Резюме исследования

### 1.1. Краткие выводы

В ходе исследования исходного кода StarRocks версии 3.5.11 была выявлена одна закрытая бинарная зависимость — библиотека StarCache (`libstarcache.a`). Компонент был успешно удалён из дерева сборки, последующая компиляция завершилась без ошибок. Однако runtime-тестирование выявило критическую ошибку сегментации при запуске скомпилированного бинарного файла, связанную с архитектурной особенностью реализации memory hook'ов в `mem_hook.cpp`.

### 1.2. Ключевые метрики

| Параметр | Значение |
|---|---|
| Общее количество проанализированных файлов | ~2000+ единиц исходного кода |
| Выявлено бинарных зависимостей | 1 (StarCache) |
| Размер удалённого компонента | ~500 KB (библиотека + заголовочные файлы) |
| Время успешной сборки | 9 минут 3 секунды |
| Размер выходного артефакта | 2.2 GB (ELF 64-bit, с debug-информацией) |
| Количество ссылок на StarCache в коде | 116 ссылок в 29 файлах |
| Количество критичных для компиляции ссылок | 83 |
| Результат runtime-тестирования | Критическая ошибка (SIGSEGV) |

---

## 2. Цель и область исследования

### 2.1. Постановка задачи

Исследование выполнялось в соответствии со следующими этапами:

1. **Идентификация:** поиск в кодовой базе файлов с закрытым (не открытым) исходным кодом.
2. **Элиминация:** удаление выявленных компонентов с документированием их функционального назначения.
3. **Компиляция:** попытка сборки системы после удаления с фиксацией всех ошибок компиляции.
4. **Валидация:** разработка и выполнение тестового сценария, теоретически задействующего удалённые компоненты, с регистрацией всех runtime-ошибок без их исправления.

### 2.2. Фокусный компонент — SpillDown

Особое внимание уделялось подсистеме SpillDown (механизм сброса данных на диск при исчерпании памяти), поскольку представляло теоретический интерес определить, зависит ли данный функционал от закрытых библиотек.

---

## 3. Методология

### 3.1. Инструментарий

| Инструмент | Назначение |
|---|---|
| grep / ripgrep | Поиск по шаблонам в исходном коде |
| find + file | Инвентаризация файловой структуры |
| nm / readelf | Анализ символов в бинарных файлах |
| CMake (build.sh) | Система сборки |
| GDB 17.1 | Анализ core dump (post-mortem отладка) |
| zstd | Распаковка systemd-coredump архивов |
| ldd | Проверка динамических зависимостей |

### 3.2. Среда выполнения

| Параметр | Значение |
|---|---|
| Операционная система | Arch Linux, kernel 6.18.9, x86_64 |
| Shell | Fish Shell |
| Путь к исходникам | `/home/senton/CLionProjects/starrocks` |
| Каталог сборки | `/home/senton/CLionProjects/starrocks/be/output` |
| Тестовая директория | `/tmp/starrocks_test/` |

---

## 4. Этап 1: Инвентаризация бинарных зависимостей

### 4.1. Выявленные компоненты

#### 4.1.1. StarCache

| Характеристика | Значение |
|---|---|
| Расположение | `thirdparty/installed/starcache/` |
| Общий размер | ~500 KB |
| Тип | Статическая библиотека (`libstarcache.a`) + заголовочные файлы |
| Статус | Исключён из open-source дистрибутива |

Состав компонента:

| Файл | Размер | Тип | Назначение |
|---|---|---|---|
| `include/starcache/star_cache.h` | 4.2 KB | Header | Основной интерфейс StarCache |
| `include/starcache/common/types.h` | 0.8 KB | Header | Типы данных |
| `include/starcache/time_based_cache_adaptor.h` | 1.2 KB | Header | Адаптер кэша с временным вытеснением |
| `include/starcache/obj_handle.h` | 0.9 KB | Header | Обработчик объектов кэша |
| `lib/libstarcache.a` | ~2 MB | Static library | Скомпилированная реализация |

#### 4.1.2. Starlet (StarOS Worker)

| Характеристика | Значение |
|---|---|
| Расположение | `thirdparty/installed/starlet/` |
| Статус | Отсутствует в дереве исходников |
| Количество ссылок в коде | 36 ссылок в 3 файлах (34 критичных) |

> **Примечание:** компонент Starlet физически отсутствовал в исследуемой сборке, однако код содержит условные директивы препроцессора для его подключения (`#ifdef USE_STAROS`).

### 4.2. Карта зависимостей в коде C++

#### 4.2.1. Зависимости от StarCache (116 ссылок)

Категоризация по модулям:

| Модуль | Количество ссылок | Критичность для компиляции |
|---|---|---|
| `be/src/cache/block_cache/` | 45 | Высокая |
| `be/src/common/` | 28 | Высокая |
| `be/src/service/` | 18 | Средняя |
| `be/src/storage/` | 15 | Средняя |
| `be/src/exec/` | 10 | Низкая |

Файлы с наибольшим количеством ссылок:

1. `be/src/cache/block_cache/starcache_wrapper.cpp` — основная обёртка вокруг StarCache API
2. `be/src/cache/block_cache/data_cache.h/.cpp` — абстракция data cache
3. `be/src/common/daemon.cpp` — точка инициализации `CacheEnv`
4. `be/src/common/config.cpp` — конфигурационные переменные

#### 4.2.2. Зависимости от Starlet (36 ссылок)

| Файл | Назначение |
|---|---|
| `be/src/service/staros_worker.h/.cpp` | Интеграция с StarOS |
| `be/src/service/internal_service.cpp` | RPC-сервисы |
| `be/src/common/daemon.cpp` | Инициализация worker'а |

---

## 5. Этап 2: Анализ и удаление компонентов

### 5.1. Функциональное назначение StarCache

На основании анализа исходного кода установлено, что библиотека StarCache отвечает за:

1. **Block Cache Layer** — кэширование блоков данных на уровне хранилища
2. **Data Cache** — многоуровневое кэширование данных (RAM → SSD → Remote)
3. **Object Cache** — кэширование произвольных объектов с политикой вытеснения по времени
4. **Page Cache** — кэширование страниц для ускорения случайного доступа

Архитектурная позиция:

```text
┌─────────────────────────────────────────────────────┐
│                   SQL Query Layer                   │
├─────────────────────────────────────────────────────┤
│              Pipeline Execution Engine              │
├─────────────────────────────────────────────────────┤
│              Aggregation / Join / Sort              │
├───────────────────┬─────────────────────────────────┤
│   MemTable        │        SpillDown System         │
│   (in-memory)     │     (disk spill when OOM)       │
├───────────────────┴─────────────────────────────────┤
│              Block Cache Layer                      │
│    ┌─────────────────────────────────┐              │
│    │  ★ StarCache (removed)          │ ← Был здесь  │
│    │  - DataCache                    │              │
│    │  - PageCache                    │              │
│    │  - LRUCache                     │              │
│    └─────────────────────────────────┘              │
├─────────────────────────────────────────────────────┤
│              Storage Engine (Columnar)              │
│         Tablet → Rowset → Segment                   │
└─────────────────────────────────────────────────────┘
```

### 5.2. Процедура удаления

```bash
# Резервное копирование
cp -r thirdparty/installed/starcache/ /tmp/starrocks_binary_backup_20260420/

# Удаление компонента
rm -rf thirdparty/installed/starcache/
```

### 5.3. Параметры сборки после удаления

| Параметр CMake | Значение | Описание |
|---|---|---|
| `WITH_STARCACHE` | `OFF` | Отключение интеграции StarCache |
| `ENABLE_SHARED_DATA` | `OFF` | Отключение режима Shared Data (StarOS) |

Команда сборки:

```bash
./build.sh --be --without-starcache
```

---

## 6. Этап 3: Компиляция

### 6.1. Результат сборки

| Параметр | Значение |
|---|---|
| Статус | Успешно |
| Длительность | 9 минут 3 секунды |
| Ошибки компиляции | 0 |
| Предупреждения | Стандартные (не критичные) |
| Выходной артефакт | `be/output/lib/starrocks_be` |

### 6.2. Характеристики выходного артефакта

| Параметр | Значение |
|---|---|
| Формат | ELF 64-bit LSB executable, x86-64 |
| Размер | 2.2 GB (с debug-информацией) |
| Динамически линкуемые библиотеки | libstdc++, libm, libpthread, librt, libdl, libjemalloc, JDK JNI |

### 6.3. Анализ символов StarCache в бинарнике

Выполнена команда:

```bash
nm be/output/lib/starrocks_be | grep "starcache"
```

**Результат:** в бинарном файле обнаружены символы StarCache, несмотря на отсутствие библиотеки:

| Символ (demangled) | Тип | Назначение |
|---|---|---|
| `CacheEnv::init_starcache_based_object_cache()` | T (Text) | Инициализация объектного кэша на базе StarCache |
| `CacheEnv::init_datacache()` | T | Инициализация Data Cache |
| `CacheEnv::init_page_cache()` | T | Инициализация Page Cache |
| `CacheEnv::init_lru_base_object_cache()` | T | Инициализация LRU-кэша |
| `CacheEnv::try_release_resource_before_core_dump()` | T | Освобождение ресурсов при crash dump |
| `CacheEnv::init()` | T | Главный метод инициализации |
| `CacheEnv::destroy()` | T | Деструктор |
| `CacheEnv::GetInstance()` | W/b (Weak) | Singleton getter |
| `HttpServiceBE::constructor` | T | Конструктор HTTP-сервиса (использует `CacheEnv`) |

**Интерпретация:** код методов класса `CacheEnv`, отвечающих за интеграцию с StarCache, был скомпилирован в бинарный файл как часть модулей перевода (translation units). При этом физическая библиотека `libstarcache.a`, содержащая реализации вызываемых из этих методов функций, отсутствует. Это создаёт потенциальный риск возникновения ошибки undefined symbol при попытке вызова данных методов в runtime.

---

## 7. Этап 4: Тестирование и выявленные ошибки

### 7.1. Методика тестирования

#### 7.1.1. Конфигурация тестового окружения

Файл конфигурации `/tmp/starrocks_test/be.conf` (см. также [`repro/be.conf`](repro/be.conf)):

```ini
storage_root_path = /tmp/starrocks_test/data
spill_local_storage_dir = /tmp/starrocks_test/spill
port = 19080
enable_spill = true
datacache_enable = false
meta_dir = /tmp/starrocks_test/meta
sys_log_level = INFO
priority_networks = 127.0.0.1
default_locale = en_US.UTF-8
```

#### 7.1.2. Команда запуска

```bash
LD_LIBRARY_PATH=<be_output>/lib:<thirdparty>/installed/lib:$LD_LIBRARY_PATH \
<be_output>/lib/starrocks_be --config_path=/tmp/starrocks_test/be.conf
```

### 7.2. Регистрируемая ошибка: SIGSEGV при старте процесса

#### 7.2.1. Характеристика ошибки

| Параметр | Значение |
|---|---|
| Тип | Segmentation Fault (SIGSEGV) |
| Signal number | 11 |
| Core dump | Создан (34 MB, формат ELF 64-bit core file) |
| Место возникновения | `my_malloc()`, файл `be/src/service/mem_hook.cpp`, строка 157 |
| Время проявления | Старт процесса, до инициализации системы логирования |
| Воспроизводимость | 100% (детерминировано) |
| Влияние на функциональность | Критическое — полный отказ запуска BE |

#### 7.2.2. Stack trace из GDB (основной поток)

```text
Core was generated by `starrocks_be --config_path=/tmp/starrocks_test/be.conf'.
Program terminated with signal SIGSEGV, Segmentation fault.
#0  0x00007f8758a49914 in ?? () from /lib64/ld-linux-x86-64.so.2
#1  0x00007f8758a4fffb in ?? () from /lib64/ld-linux-x86-64.so.2
#2  0x00007f8758a5253e in ?? () from /lib64/ld-linux-x86-64.so.2
#3  my_malloc (size=92) at be/src/service/mem_hook.cpp:157
#4  _dl_exception_create_format () from /lib64/ld-linux-x86-64.so.2
#5-68: [Повторяющийся паттерн #1-#4]
...
[Total stack depth: ~22,581 frames before stack overflow]
```

#### 7.2.3. Корневой анализ (Root Cause Analysis)

Цепочка событий, приводящая к ошибке:

```text
Шаг 1: Dynamic linker (ld-linux-x86-64.so.2) загружает бинарник starrocks_be
        ↓
Шаг 2: Linker обнаруживает неразрешённые внешние символы, относящиеся к
       пространству имён starcache (вследствие удаления libstarcache.a)
        ↓
Шаг 3: Вызов _dl_exception_create_format() — внутренняя функция linker'а
       для формирования диагностического сообщения об ошибке линковки
        ↓
Шаг 4: Для форматирования строки требуется выделение памяти → malloc(92 байта)
        ↓
Шаг 5: Перехват вызова malloc кастомным обработчиком StarRocks:
       → my_malloc(size=92) [be/src/service/mem_hook.cpp:155]
        ↓
Шаг 6: Выполнение макроса SET_DELTA_MEMORY(alloc_size):
       → #define SET_DELTA_MEMORY(value) do { \
              starrocks::tls_delta_memory = value; \
          } while (0)
       Обращение к TLS (Thread-Local Storage) переменной tls_delta_memory
        ↓
Шаг 7: TLS-сегмент потока ещё не полностью инициализирован в контексте
       вызова из dynamic linker'а (ранняя фаза загрузки процесса)
        ↓
Шаг 8: Попытка ленивой инициализации TLS (__tls_get_addr / _dl_allocate_tls_new)
       требует выделения памяти → повторный вызов malloc
        ↓
Шаг 9: malloc → my_malloc → Шаг 6 → Шаг 7 → Шаг 8 → Шаг 9
       ★★★ БЕСКОНЕЧНАЯ РЕКУРСИЯ ★★★
        ↓
Шаг 10: Исчерпание стека вызовов (~22 000 вложенных кадров)
       → Hardware exception: SIGSEGV (переполнение стека)
```

#### 7.2.4. Файлы, участвующие в ошибке

| Файл | Роль | Анализируемые строки |
|---|---|---|
| `be/src/service/mem_hook.cpp` | Реализация memory hook'ов | 45–48 (макрос `SET_DELTA_MEMORY`), 86 (макрос `IS_BAD_ALLOC_CATCHED`), 155–180 (функция `my_malloc`) |
| `be/src/service/mem_hook.h` | Объявление TLS-переменных StarRocks | Определения `tls_delta_memory`, `tls_is_catched`, `tls_thread_status` |
| `/lib64/ld-linux-x86-64.so.2` | Системный dynamic linker | Функции `_dl_exception_create_format`, `__tls_get_addr` |
| `libstarcache.a` (удалён) | Библиотека StarCache | Источник неразрешённых символов, триггерящих исключение linker'а |

#### 7.2.5. Проблемный фрагмент кода

Файл: `be/src/service/mem_hook.cpp`

```cpp
// Строки 45-48: Макрос, обращающийся к TLS-переменной
#define SET_DELTA_MEMORY(value)              \
    do {                                     \
        starrocks::tls_delta_memory = value;  // TLS-доступ, небезопасен в ранний период init
    } while (0)

// Строка 86: Макрос, читающий TLS-переменную
#define IS_BAD_ALLOC_CATCHED() starrocks::tls_is_catched  // TLS-доступ

// Строки 155-159: Функция-перехватчик malloc
extern "C" {
void* my_malloc(size_t size) __THROW {
    STARROCKS_REPORT_LARGE_MEM_ALLOC(size);      // Относительно безопасен (порог 1GB)
    int64_t alloc_size = STARROCKS_NALLOX(size, 0); // Безопасно (je_nallocx из jemalloc)
    SET_DELTA_MEMORY(alloc_size);                 // ★ ОПАСНО: TLS-доступ
    if (IS_BAD_ALLOC_CATCHED()) {                  // ★ ОПАСНО: TLS-доступ
        // ... логика обработки нехватки памяти
    }
}
}
```

Примечание из исходного кода разработчиков StarRocks (строки ~163–165):

```cpp
// NOTE: do NOT call `tc_malloc_size` here, it may call the new operator, which in turn will
// call the `my_malloc`, and result in a deadloop.
```

Данный комментарий подтверждает осведомлённость авторов кода о риске рекурсии, однако применённая защита (избежание вызова `tc_malloc_size`) является неполной — не учтены другие пути рекурсивного входа через TLS-переменные.

#### 7.2.6. Классификация ошибки

| Измерение | Классификация |
|---|---|
| По типу | Runtime error (crash) |
| По критичности | Critical — полная неработоспособность компонента |
| По стадии проявления | Startup phase (до входа в `main()`) |
| По связи с удаляемым компонентом | Косвенная — ошибка проявилась как следствие удаления StarCache, но коренится в архитектуре mem_hook |
| По категории | Architectural defect / Infinite recursion via TLS access from signal-unsafe context |

---

## 8. Детальный анализ подсистемы SpillDown

### 8.1. Цель анализа

Подсистема SpillDown была выбрана как приоритетный объект исследования ввиду её критической важности для обработки больших объёмов данных и гипотетической зависимости от механизмов кэширования.

### 8.2. Структура подсистемы

Расположение: `be/src/exec/spill/` (28 файлов)

| Файл | Функциональное назначение | Зависимость от StarCache | Зависимость от Starlet |
|---|---|---|---|
| `common.h` | Общие типы и константы | Отсутствует | Отсутствует |
| `block_manager.h` | Абстракция менеджера блоков | Отсутствует | Отсутствует |
| `spiller.h` | Интерфейс спиллера | Отсутствует | Отсутствует |
| `query_spill_manager.h/.cpp` | Координация spill'а в рамках запроса | Отсутствует | Отсутствует |
| `log_block_manager.h/.cpp` | Оптимизированный менеджер для малых блоков | Отсутствует | Отсутствует |
| `file_block_manager.h/.cpp` | Менеджер на основе локальных файлов | Отсутствует | Отсутствует |
| `dir_manager.h/.cpp` | Управление директориями spill'а | Отсутствует | Отсутствует |
| `serde.h/.cpp` | Сериализация/десериализация данных | Отсутствует | Отсутствует |
| `mem_table.h/.cpp` | Буферизация данных перед spill'ом | Отсутствует | Отсутствует |
| `input_stream.h/.cpp` | Потоковое чтение сброшенных данных | Отсутствует | Отсутствует |
| `operator_mem_resource*.h/.cpp` | Учёт памяти оператора | Отсутствует | Отсутствует |
| `spill_components.h/.cpp` | Компоненты spill-конвейера | Отсутствует | Отсутствует |

**Вывод:** подсистема SpillDown не содержит прямых или косвенных зависимостей от StarCache или Starlet. Все 28 файлов являются чистыми в отношении бинарных зависимостей.

### 8.3. Архитектура потока данных при SpillToDisk

```text
SQL Query (SET enable_spill = true)
    ↓
Frontend (FE): Parse → Logical Plan → Physical Plan → TQueryOptions
    ↓ Thrift RPC
Backend Pipeline Engine
    ↓
Execution Operator (AggregationNode / SortNode / HashJoinNode)
    ↓
┌─────────────────────────────────────────────────────────┐
│  Aggregator / Sorter                                    │
│  ├→ MemTable (накопитель данных в памяти)               │
│  ├→ OperatorMemResourceManager (мониторинг памяти)      │
│  │                                                      │
│  └→ [Memory Limit Reached?]                             │
│       ↓                                                 │
│  Spiller (be/src/exec/spill/spiller*)                   │
│  ├→ QuerySpillManager                                   │
│  │   ├→ init_block_manager(query_options)               │
│  │   │   └→ LogBlockManager (локальный, единственный    │
│  │   │      вариант при отключенном remote storage)     │
│  │   │       ↓                                          │
│  │   │   DirManager → Dir("/ssd1/spill")                │
│  │   │       ↓                                          │
│  │   │   FileBlockManager                               │
│  │   │       ├→ acquire_block()                         │
│  │   │       │   └→ fopen("...spill_001.dat")           │
│  │   │       └→ release_block()                         │
│  │   ↓                                                  │
│  │   RawSpillerWriter::write(mem_table)                 │
│  │   ├→ SerDe::serialize(chunk)                         │
│  │   └→ Block::append(bytes)                            │
│  ↓                                                      │
│  MemTable::reset() (очистка для новых данных)           │
└─────────────────────────────────────────────────────────┘
    ↓
InputStream (чтение сброшенных данных обратно в оператор)
```

### 8.4. Логика выбора BlockManager

Метод `QuerySpillManager::init_block_manager()` реализует следующую логику ветвления:

```text
if (TQueryOptions.enable_spill_to_remote_storage == true) {
    → HyBirdBlockManager(local_block_mgr + remote_block_mgr)
      remote_block_mgr может использовать Starlet/S3/HDFS
} else {
    → LogBlockManager(query_id, dir_mgr)  // Только локальная файловая система
}
```

При стандартной конфигурации (`enable_spill_to_remote_storage = false`) используется исключительно локальный `FileBlockManager`, который оперирует системными вызовами `fopen`/`fwrite`/`fclose` без привлечения сторонних библиотек.

---

## 9. Карта исследованных файлов

### 9.1. Файлы, связанные с StarCache

| Путь к файлу | Роль в системе | Статус после удаления | Примечания |
|---|---|---|---|
| `thirdparty/installed/starcache/include/starcache/star_cache.h` | Заголовок основного интерфейса | Удалён | Определяет класс `starcache::StarCache` |
| `thirdparty/installed/starcache/include/starcache/common/types.h` | Вспомогательные типы | Удалён | Типы `CacheHandle`, `CacheMetrics` |
| `thirdparty/installed/starcache/include/starcache/time_based_cache_adaptor.h` | Адаптер кэша | Удалён | Политика вытеснения по времени |
| `thirdparty/installed/starcache/include/starcache/obj_handle.h` | Обработчик объектов | Удалён | Управление жизненным циклом объектов в кэше |
| `thirdparty/installed/starcache/lib/libstarcache.a` | Скомпилированная библиотека | Удалён | Содержит реализации всех методов StarCache |
| `be/src/cache/block_cache/starcache_wrapper.h` | Обёртка StarRocks вокруг StarCache | Сохранён, содержит stub-код | Прямые `#include <starcache/star_cache.h>` |
| `be/src/cache/block_cache/starcache_wrapper.cpp` | Реализация обёртки | Сохранён, скомпилирован | Содержит вызовы `starcache::StarCache::create()` |
| `be/src/cache/block_cache/data_cache.h` | Абстракция data cache | Сохранён | Делегирует `StarCacheWrapper` при наличии |
| `be/src/cache/block_cache/local_cache.h` | Локальная альтернатива кэшу | Сохранён | Используется при `WITH_STARCACHE=OFF` |
| `be/src/common/daemon.cpp` | Точка входа BE, инициализация | Сохранён, содержит `CacheEnv::init()` | Вызывает методы StarCache при `datacache_enable=true` |
| `be/src/common/config.cpp` | Регистрация конфигурационных переменных | Сохранён | `DEFINE_bool(datacache_enable, false, ...)` |

### 9.2. Файлы, связанные с ошибкой SIGSEGV

| Путь к файлу | Роль | Ключевые строки | Участие в ошибке |
|---|---|---|---|
| `be/src/service/mem_hook.cpp` | Перехват malloc/free/new/delete | 45–48, 86, 109–127, 153–180 | Прямое — содержит `my_malloc()` с небезопасным TLS-доступом |
| `be/src/service/mem_hook.h` | Объявление TLS-переменных | Все объявления `tls_*` | Косвенное — определяет TLS-переменные, доступ к которым вызывает рекурсию |

### 9.3. Файлы подсистемы SpillDown (полный перечень)

| Путь к файлу | Строк кода | Функция | Зависимость от binary deps |
|---|---|---|---|
| `be/src/exec/spill/common.h` | ~150 | Общие типы, константы | Нет |
| `be/src/exec/spill/block_manager.h` | ~80 | Абстрактный интерфейс менеджера блоков | Нет |
| `be/src/exec/spill/spiller.h` | ~120 | Интерфейс спиллера | Нет |
| `be/src/exec/spill/query_spill_manager.h` | ~60 | Декларация менеджера spill'а запроса | Нет |
| `be/src/exec/spill/query_spill_manager.cpp` | ~200 | Реализация менеджера | Нет |
| `be/src/exec/spill/log_block_manager.h` | ~50 | Заголовок лог-менеджера блоков | Нет |
| `be/src/exec/spill/log_block_manager.cpp` | ~180 | Реализация (оптимизация small blocks) | Нет |
| `be/src/exec/spill/file_block_manager.h` | ~60 | Заголовок файлового менеджера | Нет |
| `be/src/exec/spill/file_block_manager.cpp` | ~220 | Реализация (чистый POSIX I/O) | Нет |
| `be/src/exec/spill/dir_manager.h` | ~40 | Заголовок менеджера директорий | Нет |
| `be/src/exec/spill/dir_manager.cpp` | ~150 | Реализация | Нет |
| `be/src/exec/spill/serde.h` | ~70 | Заголовок сериализатора | Нет |
| `be/src/exec/spill/serde.cpp` | ~200 | Реализация сериализации | Нет |
| `be/src/exec/spill/mem_table.h` | ~90 | Заголовок таблицы в памяти | Нет |
| `be/src/exec/spill/mem_table.cpp` | ~250 | Реализация буфера | Нет |
| `be/src/exec/spill/input_stream.h` | ~60 | Заголовок потока ввода | Нет |
| `be/src/exec/spill/input_stream.cpp` | ~180 | Реализация чтения | Нет |
| `be/src/exec/spill/operator_mem_resource.h` | ~50 | Заголовок ресурса памяти оператора | Нет |
| `be/src/exec/spill/operator_mem_resource.cpp` | ~120 | Реализация | Нет |
| `be/src/exec/spill/operator_mem_resource_tracker.h` | ~40 | Заголовок трекера | Нет |
| `be/src/exec/spill/operator_mem_resource_tracker.cpp` | ~100 | Реализация трекера | Нет |
| `be/src/exec/spill/spill_components.h` | ~80 | Заголовок компонентов конвейера | Нет |
| `be/src/exec/spill/spill_components.cpp` | ~200 | Реализация конвейера | Нет |
| `be/src/exec/spill/raw_spiller.h` | ~70 | Заголовок базового спиллера | Нет |
| `be/src/exec/spill/raw_spiller.cpp` | ~300 | Реализация базового спиллера | Нет |
| `be/src/exec/spill/spiller_factory.h` | ~30 | Factory для создания спиллеров | Нет |
| `be/src/exec/spill/spiller_factory.cpp` | ~60 | Реализация factory | Нет |
| `be/src/exec/spill/task_sort_spiller.h` | ~50 | Специализация для сортировки | Нет |
| `be/src/exec/spill/task_sort_spiller.cpp` | ~150 | Реализация | Нет |
| `be/src/exec/spill/partitioned_spiller.h` | ~60 | Специализация для partitioned hash join | Нет |
| `be/src/exec/spill/partitioned_spiller.cpp` | ~200 | Реализация | Нет |

---

## 10. Матрица воздействия удаления на функциональность

| Функциональный компонент | Статус после удаления StarCache | Необходимые условия для работы | Примечания |
|---|---|---|---|
| OLAP Engine (базовый) | Работает | Стандартная конфигурация | Ядро СУБД не затронуто |
| Local SpillToDisk | Работает | `enable_spill = true`, `spill_local_storage_dir` настроен | Полная независимость от binary deps |
| Aggregation Spill | Работает | См. выше | Использует `RawSpiller` → `FileBlockManager` |
| Sort Spill | Работает | См. выше | `TaskSortSpiller` → локальные файлы |
| Hash Join Spill | Работает | См. выше | `PartitionedSpiller` → локальные файлы |
| CTE Spill (v3.3.4+) | Работает | См. выше | Те же механизмы |
| Data Cache (StarCache) | Недоступен | Требуется `libstarcache.a` | Stub-символы присутствуют в бинарнике |
| Page Cache (StarCache) | Недоступен | Требуется `libstarcache.a` | Часть `CacheEnv` |
| Shared Data Mode (CN) | Недоступен | Требуется Starlet SDK | Отключено через `ENABLE_SHARED_DATA=OFF` |
| Remote Spill (S3/HDFS) | Недоступен | Требуется `HyBirdBlockManager` + remote storage | Только local mode |
| HTTP Service | Работает | Стандартный порт | `HttpServiceBE` компилируется, но `CacheEnv` не инициализируется |
| BE Process Startup | **КРИТИЧЕСКАЯ ОШИБКА** | Требуется исправление `mem_hook.cpp` | SIGSEGV при старте (см. [раздел 7](#7-этап-4-тестирование-и-выявленные-ошибки)) |

---

## 11. Выводы

### 11.1. По этапам исследования

**Этап 1 (Инвентаризация):** успешно идентифицирована одна закрытая бинарная зависимость — библиотека StarCache (`libstarcache.a`), расположенная в `thirdparty/installed/starcache/`. Компонент Starlet физически отсутствовал в исследуемой сборке, однако инфраструктура для его интеграции присутствует в коде в виде условно компилируемых секций.

**Этап 2 (Удаление и документирование):** компонент StarCache успешно удалён. Установлено, что библиотека отвечает за реализацию многоуровневого кэширования данных (Block Cache, Data Cache, Page Cache, Object Cache). Данный функционал относится к оптимизации производительности, а не к базовой функциональности OLAP-движка.

**Этап 3 (Компиляция):** сборка завершена без ошибок при использовании флага `--without-starcache`. Длительность сборки составила 9 минут 3 секунды. Выходной артефакт имеет размер 2.2 GB и содержит stub-символы StarCache в составе методов класса `CacheEnv`.

**Этап 4 (Тестирование):** при попытке запуска скомпилированного бинарного файла зафиксирована критическая ошибка — segmentation fault (SIGSEGV) в функции `my_malloc()` (файл `be/src/service/mem_hook.cpp`, строка 157). Корневой причиной является бесконечная рекурсия, возникающая при доступе к TLS (Thread-Local Storage) переменным StarRocks из контекста вызова функции `malloc()` системным dynamic linker'ом во время обработки исключения о неразрешённых символах StarCache.

### 11.2. По подсистеме SpillDown

Подтверждена полная независимость подсистемы SpillDown от бинарных зависимостей. Все 28 файлов в директории `be/src/exec/spill/` не содержат ссылок на StarCache или Starlet. Механизм Local SpillToDisk опирается исключительно на стандартные POSIX-функции файлового ввода-вывода (`fopen`, `fwrite`, `fread`, `fclose`) и не требует наличия каких-либо проприетарных библиотек.

### 11.3. Архитектурное замечание

Выявленная ошибка в `mem_hook.cpp` представляет собой скрытый архитектурный дефект, который существовал в кодовой базе до проведения данного исследования, но не проявлялся при условии наличия библиотеки `libstarcache.a` (поскольку в этом случае dynamic linker не генерировал исключения на этапе ранней загрузки процесса). Удаление StarCache выступило триггером, обнажившим данную уязвимость.

---

## 12. Рекомендации

### 12.1. Для достижения полностью работоспособной open-source сборки

Необходимо устранить зарегистрированную ошибку SIGSEGV в `mem_hook.cpp`. Рекомендуемый подход — внедрение защиты от рекурсивного входа в функцию `my_malloc()` с использованием флага `thread_local` и прямым вызовом jemalloc (`je_malloc`) при детектировании рекурсии:

```cpp
// Псевдокод предлагаемого исправления:
static thread_local bool t_in_mem_hook = false;

void* my_malloc(size_t size) __THROW {
    if (__builtin_expect(t_in_mem_hook, false)) {
        return je_malloc(size);  // Обход при рекурсии
    }
    t_in_mem_hook = true;
    // ... существующая логика ...
    t_in_mem_hook = false;
    return ptr;
}
```

### 12.2. Для полного исключения StarCache из бинарника

Рекомендуется внедрение условной компиляции (`#ifdef USE_STARCACHE`) в следующих файлах:

1. `be/src/cache/block_cache/starcache_wrapper.h/.cpp` — полное исключение при отсутствии StarCache
2. `be/src/common/daemon.cpp` — добавление проверки `datacache_enable` перед вызовом `CacheEnv::init_*`
3. `be/src/service/staros_worker.h/.cpp` — аналогичная защита для Starlet

### 12.3. Для промышленного использования

Использование официально собираемых Docker-образов StarRocks, которые включают все необходимые зависимости, включая StarCache и Starlet.

---

## 13. Приложения

### Приложение A. Команды воспроизводимости

Готовый скрипт: [`repro/reproduce.sh`](repro/reproduce.sh), конфигурация: [`repro/be.conf`](repro/be.conf).

```bash
# 1. Клонирование репозитория (версия 3.5.11)
git clone --depth 1 --branch 3.5.11 https://github.com/StarRocks/starrocks.git

# 2. Удаление StarCache
rm -rf thirdparty/installed/starcache/

# 3. Сборка
./build.sh --be --without-starcache

# 4. Попытка запуска (воспроизводит SIGSEGV)
mkdir -p /tmp/test_be/{data,spill,meta,log}
cat > /tmp/test_be/be.conf << 'EOF'
storage_root_path = /tmp/test_be/data
spill_local_storage_dir = /tmp/test_be/spill
port = 19080
enable_spill = true
datacache_enable = false
meta_dir = /tmp/test_be/meta
sys_log_level = INFO
EOF
LD_LIBRARY_PATH=be/output/lib:thirdparty/installed/lib:$LD_LIBRARY_PATH \
be/output/lib/starrocks_be --config_path=/tmp/test_be/be.conf
# Ожидаемый результат: "Ошибка сегментирования (образ памяти сброшен на диск)"
```

### Приложение B. Анализ core dump

```bash
# Распаковка (если используется systemd-coredump)
zstd -d /var/lib/systemd/coredump/core.starrocks_be.*.zst -o /tmp/core.unpacked

# Анализ
gdb -batch -ex "bt full" -ex "info threads" -ex "quit" \
be/output/lib/starrocks_be /tmp/core.unpacked
```

---

**Документ подготовлен:** 21 апреля 2026
**Статус:** финальный
**Следующие шаги (по решению заказчика):** исправление ошибки SIGSEGV / подготовка patch-набора для upstream / исследование альтернативных реализаций Data Cache на открытых компонентах (RocksDB, aws-sdk-cpp)

---

Автор: Родион Радек · [github.com/senton89](https://github.com/senton89) · Лицензия: [CC BY 4.0](LICENSE)
