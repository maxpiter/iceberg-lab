# Снимки, путешествие во времени и изменение схемы

В главе [02-first-table.md](02-first-table.md) было видно, что Iceberg никогда не переписывает файлы на месте: каждая запись добавляет новые файлы и новый снимок (snapshot). Снимок - это состояние таблицы на момент записи. Пока старые снимки не удалены, к ним можно обратиться запросом или вернуть таблицу в одно из них.

Здесь вы поработаете со снимками и поменяете схему таблицы без перезаливки данных.

Чтобы не портить `orders` из прошлых глав, создайте копию. Всё выполняется под `engineer`:

```sql
CREATE TABLE lakekeeper.sales.orders_tt
WITH (partitioning = ARRAY['year(orderdate)'])
AS SELECT * FROM tpch.tiny.orders;
```

## Шаг 1. Несколько изменений подряд

Удалите часть строк и обновите одну:

```sql
DELETE FROM lakekeeper.sales.orders_tt WHERE orderstatus = 'P';

UPDATE lakekeeper.sales.orders_tt SET orderpriority = '1-URGENT' WHERE orderkey = 1;
```

Посмотрите на снимки:

```sql
SELECT committed_at, snapshot_id, operation,
       element_at(summary, 'added-records')          AS added_rows,
       element_at(summary, 'added-position-deletes') AS deleted_rows,
       element_at(summary, 'total-records')          AS total_rows
FROM lakekeeper.sales."orders_tt$snapshots"
ORDER BY committed_at;
```

Будет три снимка. `element_at` вместо `summary['...']` нужен потому, что не в каждом снимке есть все ключи, и обращение через скобки на отсутствующем ключе даёт ошибку.

Снимки:

| operation | Что произошло |
|---|---|
| `append` | создание таблицы, 15 000 строк |
| `delete` | удаление 363 строк со статусом `P` |
| `overwrite` | обновление одной строки |

`total-records` в снимке `delete` по-прежнему 15 000. Iceberg не переписал файлы данных, а добавил маленький файл удалений: в нём перечислено, какие строки каких файлов считать удалёнными. Это видно по служебной таблице файлов:

```sql
SELECT content, count(*) AS files, sum(record_count) AS records
FROM lakekeeper.sales."orders_tt$files"
GROUP BY content;
```

`content = 0` - файлы данных, `content = 1` - файлы удалений по позиции строки. `UPDATE` в Iceberg устроен как удаление старой строки плюс запись новой, поэтому он добавил и файл удалений, и файл данных с одной строкой.

При чтении Trino накладывает файлы удалений на файлы данных. Когда таких файлов много, чтение замедляется - их сливает обратно процедура `optimize`, см. [05-maintenance.md](05-maintenance.md).

## Шаг 2. Кто менял таблицу

В каждом снимке Trino записывает, кто его создал:

```sql
SELECT committed_at, operation, summary['trino_user'] AS author
FROM lakekeeper.sales."orders_tt$snapshots"
ORDER BY committed_at;
```

В `author` будет идентификатор engineer из Keycloak. Каталог при этом видит только техническую учётку `trino` (см. [03-access.md](03-access.md)), а настоящий автор изменения сохраняется в истории самой таблицы.

## Шаг 3. Путешествие во времени

Скопируйте `snapshot_id` первого снимка (`append`) из запроса шага 1 и прочитайте таблицу в том состоянии:

```sql
SELECT count(*)
FROM lakekeeper.sales.orders_tt FOR VERSION AS OF 5412117735114076835;
```

Подставьте свой номер снимка. Запрос вернёт 15 000 строк, хотя в текущей таблице их меньше:

```sql
SELECT count(*) FROM lakekeeper.sales.orders_tt;
```

Вместо номера снимка можно указать момент времени. Возьмите время из `committed_at` между первым и вторым снимком:

```sql
SELECT count(*)
FROM lakekeeper.sales.orders_tt FOR TIMESTAMP AS OF TIMESTAMP '2026-10-11 18:36:28 UTC';
```

Путешествие во времени - это обычное чтение, для него достаточно права `select`. analyst, которому выдали чтение таблицы, тоже может смотреть её прошлые состояния.

## Шаг 4. Изменение схемы

Добавьте колонку и переименуйте другую:

```sql
ALTER TABLE lakekeeper.sales.orders_tt ADD COLUMN discount double;

ALTER TABLE lakekeeper.sales.orders_tt RENAME COLUMN clerk TO manager;

SELECT orderkey, manager, discount FROM lakekeeper.sales.orders_tt LIMIT 5;
```

Обе команды выполнились мгновенно, данные не перезаписывались. У старых строк в `discount` будет `NULL`. Iceberg хранит колонки по внутренним номерам, а не по именам, поэтому переименование меняет только метаданные, и старые файлы Parquet читаются под новым именем.

Снимков от этого не прибавилось - проверьте `$snapshots`. Изменение схемы создаёт новый `metadata.json`, но не новый снимок данных.

Прочитайте первый снимок ещё раз:

```sql
SELECT * FROM lakekeeper.sales.orders_tt FOR VERSION AS OF 5412117735114076835 LIMIT 1;
```

Колонка будет называться `clerk`, а `discount` не будет вовсе: снимок читается со схемой, которая действовала в момент его создания.

## Шаг 5. Изменение разбивки на партиции

Сейчас таблица разбита по годам. Допустим, данных стало много, и нужна разбивка по месяцам:

```sql
ALTER TABLE lakekeeper.sales.orders_tt
SET PROPERTIES partitioning = ARRAY['month(orderdate)'];

INSERT INTO lakekeeper.sales.orders_tt
SELECT *, 0.1 FROM tpch.tiny.orders WHERE orderdate >= DATE '1998-07-01';
```

Новые строки легли по новой схеме разбивки, а старые остались как были. Посмотрите файлы за 1998 год:

```sql
SELECT file_path
FROM lakekeeper.sales."orders_tt$files"
WHERE file_path LIKE '%1998%';
```

Рядом окажутся папки `orderdate_year=1998/` (старая разбивка) и `orderdate_month=1998-07/`, `orderdate_month=1998-08/` (новая). Таблицу не пришлось пересоздавать, а запросы с условием на дату работают по обеим разбивкам. Если нужно переложить старые данные по новой схеме, это делает `optimize`.

## Шаг 6. Откат к снимку

Если изменение оказалось ошибкой, таблицу можно вернуть в прошлый снимок. Возьмите номер первого снимка:

```sql
ALTER TABLE lakekeeper.sales.orders_tt EXECUTE rollback_to_snapshot(5412117735114076835);

SELECT count(*) FROM lakekeeper.sales.orders_tt;
```

Снова 15 000 строк. Откат не удаляет более поздние снимки, он переключает текущее состояние таблицы на выбранный снимок:

```sql
SELECT made_current_at, snapshot_id, is_current_ancestor
FROM lakekeeper.sales."orders_tt$history"
ORDER BY made_current_at;
```

Снимки после отката помечены `is_current_ancestor = false`: они больше не входят в историю текущего состояния, но физически остаются, пока их не удалит `expire_snapshots`.

Откат возвращает данные, но не схему: колонки `manager` и `discount` останутся, у всех строк в `discount` будет `NULL`.

Откат меняет таблицу, поэтому нужно право на запись (`modify`). У analyst с правом `select` команда получит `Access Denied`.

> В официальных политиках OPA от Lakekeeper процедуры `rollback_to_snapshot` нет в списке разрешённых, и Trino отказывает в ней всем. Стенд добавляет её отдельным файлом `opa/policies/trino/allow_managed.rego` с тем же условием, что и для процедур обслуживания: право на запись в таблицу.

## Сколько живут снимки

Снимки и файлы, на которые они ссылаются, хранятся, пока их не удалит процедура `expire_snapshots`. Чем дольше история, тем дальше можно путешествовать во времени и тем больше места занимает таблица. Как найти баланс - в [05-maintenance.md](05-maintenance.md).

## Что запомнить

- Снимок - состояние таблицы на момент записи. `INSERT`, `DELETE`, `UPDATE` создают новый снимок.
- `DELETE` и `UPDATE` не переписывают файлы данных, а добавляют файлы удалений.
- `FOR VERSION AS OF` и `FOR TIMESTAMP AS OF` читают прошлое состояние, для этого хватает права `select`.
- Схема и разбивка на партиции меняются без перезаливки данных.
- `rollback_to_snapshot` возвращает данные к прошлому снимку и требует права на запись.
- В истории снимков записан настоящий автор изменения (`trino_user`).

Удалить копию после опытов:

```sql
DROP TABLE lakekeeper.sales.orders_tt;
```

Дальше: [05-maintenance.md](05-maintenance.md) - обслуживание таблиц.
