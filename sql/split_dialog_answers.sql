PRAGMA yt.InferSchema = "100";
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA yson.DisableStrict;
PRAGMA Yson.AutoConvert;
PRAGMA SimpleColumns;

DECLARE $input1 AS String;   -- исходная таблица с диалогом и двумя ответами
DECLARE $output1 AS String;  -- instruct_id + dialog
DECLARE $output2 AS String;  -- instruct_id + первая пара (answer_1 / answer_source_1)
DECLARE $output3 AS String;  -- instruct_id + вторая пара (answer_2 / answer_source_2)

-- Читаем один раз, дальше три раскладки одного и того же среза.
$src = (
    SELECT
        CAST(instruct_id AS String)        AS instruct_id,
        dialog                             AS dialog,
        CAST(dialog_str AS String)         AS dialog_str,
        CAST(answer_1 AS Utf8)             AS answer_1,
        CAST(answer_2 AS Utf8)             AS answer_2,
        CAST(answer_source_1 AS String)    AS answer_source_1,
        CAST(answer_source_2 AS String)    AS answer_source_2
    FROM $input1
);

-- ========================= 1. ДИАЛОГИ =========================
-- На instruct_id диалог один и тот же, поэтому схлопываем дубли:
-- MIN по yson-полю не берётся, поэтому берём произвольный элемент группы.
INSERT INTO $output1 WITH TRUNCATE
SELECT
    instruct_id                     AS instruct_id,
    SOME(dialog)                    AS dialog,
    SOME(dialog_str)                AS dialog_str
FROM $src
GROUP BY instruct_id
ORDER BY instruct_id;

-- ========================= 2. ПЕРВАЯ ПАРА =========================
INSERT INTO $output2 WITH TRUNCATE
SELECT
    instruct_id                     AS instruct_id,
    answer_1                        AS answer,
    answer_source_1                 AS answer_source
FROM $src
ORDER BY instruct_id;

-- ========================= 3. ВТОРАЯ ПАРА =========================
INSERT INTO $output3 WITH TRUNCATE
SELECT
    instruct_id                     AS instruct_id,
    answer_2                        AS answer,
    answer_source_2                 AS answer_source
FROM $src
ORDER BY instruct_id;
