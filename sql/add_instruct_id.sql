PRAGMA yt.InferSchema;
PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;

DECLARE $input1 AS String;
DECLARE $output1 AS String;

-- Копируем таблицу как есть и добавляем сквозной instruct_id = 1..n.
-- TableRecordIndex() — это номер строки внутри таблицы (с 1), считается
-- на лету при чтении, без сортировки и без свода всех данных в одну джобу.
-- Работает корректно, пока $input1 — одна статическая таблица:
-- при чтении нескольких таблиц (диапазон, конкатенация) нумерация
-- начинается заново на каждой из них.
INSERT INTO $output1 WITH TRUNCATE
SELECT
    TableRecordIndex() AS instruct_id,
    t.*
FROM $input1 AS t;
