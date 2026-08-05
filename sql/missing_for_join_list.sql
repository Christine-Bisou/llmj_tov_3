PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;   -- исходная таблица с for_join (535 строк)
DECLARE $output1 AS String;  -- строки, которые джадж не отработал
DECLARE $output2 AS String;  -- строки, которые джадж отработал

-- for_join строк, содержания которых нет в таблице с результатами джаджа.
-- Список посчитан склейкой по instruct + answer_1 + answer_2 + оба источника
-- (см. sql/missing_for_join.sql — в судейской таблице колонки for_join нет,
-- а её instruct_id это просто нумерация 1..478 самой таблицы).
$missing = AsList(
    107, 124, 142, 157, 190, 210, 211, 212, 221, 225,
    316, 324, 344, 402, 411, 415, 438, 440, 444, 454,
    457, 458, 462, 464, 467, 468, 488, 495
);

INSERT INTO $output1 WITH TRUNCATE
SELECT *
FROM $input1
WHERE for_join IN $missing
ORDER BY for_join;

INSERT INTO $output2 WITH TRUNCATE
SELECT *
FROM $input1
WHERE for_join NOT IN $missing
ORDER BY for_join;

-- Если считать потерянной и вторую копию полного дубля (в исходнике 32 таких
-- строки, джадж их схлопнул), то список длиннее — 57 строк, 535 = 478 + 57:
--
-- $missing = AsList(
--       5,   9,  17,  21,  26,  30,  34,  37,  40,  49,
--      53,  56,  64,  68,  72,  75, 105, 107, 124, 142,
--     151, 157, 190, 210, 211, 212, 219, 221, 225, 282,
--     284, 316, 321, 324, 336, 344, 377, 393, 402, 411,
--     415, 426, 438, 440, 444, 454, 456, 457, 458, 462,
--     464, 467, 468, 488, 495, 528, 535
-- );
