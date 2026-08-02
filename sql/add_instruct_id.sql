PRAGMA yt.InferSchema;
PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;

DECLARE $input1 AS String;
DECLARE $output1 AS String;

-- Копируем таблицу как есть и добавляем instruct_id = 1..n.
-- Номер не привязан к порядку строк во входе: строки перемешиваются
-- случайным ключом, и уже по нему раздаются номера.
-- RandomNumber(TableRow()) — аргумент нужен, чтобы YQL не свернул вызов
-- в одну константу на всю таблицу.
$src = (
    SELECT
        t.*,
        RandomNumber(TableRow()) AS _rnd
    FROM $input1 AS t
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    ROW_NUMBER() OVER (ORDER BY _rnd) AS instruct_id,
    s.* WITHOUT if exists s._rnd
FROM $src AS s;
