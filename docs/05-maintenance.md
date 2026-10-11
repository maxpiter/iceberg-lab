# Обслуживание таблиц

Iceberg никогда не переписывает файлы на месте (см. [02-first-table.md](02-first-table.md) и [04-snapshots.md](04-snapshots.md)). Это даёт снимки и путешествие во времени, но со временем таблица обрастает мусором:

| Что копится | Откуда | Чем мешает | Чем убирается |
|---|---|---|---|
| мелкие файлы данных | каждая запись кладёт свои файлы, поток из Kafka - особенно много | запрос открывает тысячи файлов вместо десятков | `optimize` |
| файлы удалений | `DELETE` и `UPDATE` | при чтении их нужно накладывать на данные | `optimize` |
| старые снимки | каждая запись | держат старые файлы, место не освобождается | `expire_snapshots` |
| манифесты | каждая запись добавляет свои | планирование запроса читает их все | `optimize_manifests` |
| файлы-сироты | упавшие и прерванные записи | лежат в S3, ни один снимок на них не ссылается | `remove_orphan_files` |
| старые `metadata.json` | каждое изменение таблицы | занимают место | настройки таблицы, см. ниже |

В этой главе вы создадите таблицу с мусором и уберёте его. Всё выполняется под `engineer`.

## Шаг 1. Таблица из мелких файлов

Создайте пустую таблицу и залейте в неё данные двенадцатью отдельными вставками, по месяцу за раз. Так ведёт себя загрузка небольшими порциями:

```sql
CREATE TABLE lakekeeper.sales.orders_m
WITH (partitioning = ARRAY['year(orderdate)'])
AS SELECT * FROM tpch.tiny.orders WHERE false;

INSERT INTO lakekeeper.sales.orders_m SELECT * FROM tpch.tiny.orders WHERE month(orderdate) = 1;
INSERT INTO lakekeeper.sales.orders_m SELECT * FROM tpch.tiny.orders WHERE month(orderdate) = 2;
INSERT INTO lakekeeper.sales.orders_m SELECT * FROM tpch.tiny.orders WHERE month(orderdate) = 3;
INSERT INTO lakekeeper.sales.orders_m SELECT * FROM tpch.tiny.orders WHERE month(orderdate) = 4;
INSERT INTO lakekeeper.sales.orders_m SELECT * FROM tpch.tiny.orders WHERE month(orderdate) = 5;
INSERT INTO lakekeeper.sales.orders_m SELECT * FROM tpch.tiny.orders WHERE month(orderdate) = 6;
INSERT INTO lakekeeper.sales.orders_m SELECT * FROM tpch.tiny.orders WHERE month(orderdate) = 7;
INSERT INTO lakekeeper.sales.orders_m SELECT * FROM tpch.tiny.orders WHERE month(orderdate) = 8;
INSERT INTO lakekeeper.sales.orders_m SELECT * FROM tpch.tiny.orders WHERE month(orderdate) = 9;
INSERT INTO lakekeeper.sales.orders_m SELECT * FROM tpch.tiny.orders WHERE month(orderdate) = 10;
INSERT INTO lakekeeper.sales.orders_m SELECT * FROM tpch.tiny.orders WHERE month(orderdate) = 11;
INSERT INTO lakekeeper.sales.orders_m SELECT * FROM tpch.tiny.orders WHERE month(orderdate) = 12;
```

В DBeaver удобно выделить все строки и выполнить их скриптом (Alt+X).

Посмотрите, что получилось:

```sql
SELECT count(*) AS files,
       round(avg(file_size_in_bytes) / 1024) AS avg_kb,
       sum(record_count) AS records
FROM lakekeeper.sales."orders_m$files";

SELECT count(*) AS snapshots FROM lakekeeper.sales."orders_m$snapshots";
SELECT count(*) AS manifests FROM lakekeeper.sales."orders_m$manifests";
```

Те же 15 тысяч строк, что в `orders`, лежат примерно в 80 файлах по 7 КБ вместо 7 файлов. Снимков 13, манифестов 12. На стенде это незаметно, а на настоящих объёмах запрос, который открывает сотни тысяч мелких файлов, работает в разы медленнее.

## Шаг 2. Компакция: optimize

`optimize` переписывает мелкие файлы в крупные. Обычно её запускают не на всю таблицу, а на свежие партиции, куда шла запись, чтобы каждый раз не переписывать всю историю:

```sql
ALTER TABLE lakekeeper.sales.orders_m EXECUTE optimize
WHERE orderdate >= DATE '1997-01-01';

SELECT count(*) FROM lakekeeper.sales."orders_m$files";
```

Файлов стало меньше: слиты только 1997 и 1998 годы. Условие в `WHERE` должно совпадать с границами партиций - здесь таблица разбита по годам, и условие начинается с 1 января.

Теперь всю таблицу:

```sql
ALTER TABLE lakekeeper.sales.orders_m EXECUTE optimize;

SELECT count(*) AS files, round(avg(file_size_in_bytes) / 1024) AS avg_kb
FROM lakekeeper.sales."orders_m$files";
```

7 файлов, по одному на год. `optimize` сливает файлы меньше порога, по умолчанию 100 МБ; порог можно задать: `optimize(file_size_threshold => '128MB')`. Попутно `optimize` применяет файлы удалений: строки, удалённые через `DELETE`, физически исчезают из новых файлов.

Количество строк не изменилось, а `optimize` создал новый снимок с операцией `replace`.

## Шаг 3. Манифесты: optimize_manifests

```sql
ALTER TABLE lakekeeper.sales.orders_m EXECUTE optimize_manifests;

SELECT count(*) FROM lakekeeper.sales."orders_m$manifests";
```

Манифесты переписаны в меньшее число. Для таблицы с тысячами снимков это ускоряет планирование каждого запроса.

## Шаг 4. Старые снимки: expire_snapshots

Откройте консоль RustFS (http://localhost:9101), бакет `warehouse`, папка `demo/orders_m-...`. В `data/` по-прежнему лежат и 80 старых мелких файлов, и 7 новых: старые снимки ссылаются на старые файлы, и пока снимки живы, файлы удалять нельзя. Поэтому после `optimize` место в S3 не освобождается, а наоборот, его занято больше.

Удалите старые снимки:

```sql
ALTER TABLE lakekeeper.sales.orders_m
EXECUTE expire_snapshots(retention_threshold => '0s');

SELECT count(*) FROM lakekeeper.sales."orders_m$snapshots";
```

Остался один снимок, а в `data/` - только 7 файлов. Вместе со снимками Trino удалил файлы, на которые больше никто не ссылается.

После этого путешествие во времени к удалённым снимкам невозможно. `retention_threshold` задаёт, снимки старше какого возраста удалять, и тем самым - насколько далеко в прошлое можно будет заглянуть.

## Шаг 5. Сироты: remove_orphan_files

Сирота - файл в папке таблицы, на который не ссылается ни один снимок. Обычно они остаются от записей, которые упали на середине: файлы данных уже записаны, а снимок так и не появился.

На стенде сироту проще подложить руками. В консоли RustFS загрузите любой файл в папку `data/` таблицы `orders_m` (кнопка загрузки в интерфейсе папки). Затем:

```sql
ALTER TABLE lakekeeper.sales.orders_m
EXECUTE remove_orphan_files(retention_threshold => '0s');
```

Обновите папку в RustFS - подложенного файла больше нет.

## Сроки хранения: почему здесь везде 0s

По умолчанию Trino не даёт удалять снимки и сирот моложе 7 дней. В стенде это ограничение снято (`iceberg.expire-snapshots.min-retention` и `iceberg.remove-orphan-files.min-retention` в `trino/catalog/lakekeeper.properties`), чтобы результат был виден сразу.

В рабочей системе ноль ставить нельзя. Запись, которая идёт прямо сейчас, уже положила свои файлы, но ещё не создала снимок - для `remove_orphan_files` они выглядят как сироты. С нулевым сроком процедура удалит их, и запись закончится испорченной таблицей. Срок хранения должен быть заметно больше самой долгой записи.

## Порядок и расписание

Типичный порядок:

1. `optimize` по свежим партициям;
2. `expire_snapshots`;
3. `remove_orphan_files`;
4. `optimize_manifests`, реже остальных.

`expire_snapshots` идёт после `optimize`, потому что именно он освобождает место от файлов, которые `optimize` заменил. Запускает всё это обычно планировщик по ночам, по каждой таблице, куда шла запись.

Lakekeeper умеет часть работы делать сам. В версии 0.13 у каталога есть фоновые задачи для истечения снимков и удаления сирот: включаются на warehouse или на отдельную таблицу и по умолчанию выключены (см. [Table Maintenance](https://docs.lakekeeper.io/docs/0.13.x/table-maintenance/)). Их ход виден на вкладке TASKS таблицы в UI Lakekeeper. Компакцию каталог не делает, `optimize` запускает движок.

## Старые metadata.json

Каждое изменение таблицы, включая `ALTER TABLE` и процедуры обслуживания, создаёт новый `metadata.json`. Процедуры выше их не удаляют. За это отвечают свойства таблицы `write.metadata.delete-after-commit.enabled` и `write.metadata.previous-versions-max`: Lakekeeper по умолчанию хранит последние 100 версий и удаляет более старые при очередной записи. Trino менять эти свойства не даёт, их задают через другие клиенты каталога, например Spark.

## Кто может обслуживать таблицу

Процедуры обслуживания меняют таблицу, поэтому для них нужно право на запись (`modify`). Проверьте под `analyst`, если у него есть только чтение:

```sql
ALTER TABLE lakekeeper.sales.orders EXECUTE optimize;
-- Access Denied: Cannot execute table procedure OPTIMIZE on lakekeeper.sales.orders
```

На практике обслуживание запускают под отдельной технической учёткой с правом записи на нужные схемы, а не под учёткой человека.

## Что запомнить

- Мелкие файлы, снимки, манифесты, сироты и старые метаданные копятся при любой нагрузке на запись.
- `optimize` сливает файлы, `expire_snapshots` удаляет старые снимки и освобождает место, `remove_orphan_files` убирает сирот, `optimize_manifests` сжимает манифесты.
- Место в S3 освобождается только после `expire_snapshots`.
- В рабочей системе сроки хранения не ставят в ноль.
- Для обслуживания нужно право на запись в таблицу.

Удалить таблицу после опытов:

```sql
DROP TABLE lakekeeper.sales.orders_m;
```

Дальше: [06-limitations.md](06-limitations.md) - что в стенде упрощено и что нужно до рабочей системы.
