-- Приклеиваем agg_tov_markup и raw_tov_markup к исходной таблице задач.
-- input1 — исходная таблица (instruct_id лежит внутри input_meta),
-- input2 — второй выход judge_merge_pretty.sql.

DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;

PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

$orig = (
    SELECT
        o.*,
        CAST(Yson::LookupString(o.input_meta, 'instruct_id') AS String) AS join_key,
        -- колонки перезаписываем: если прошлый прогон их уже приклеил,
        -- без WITHOUT будет дубликат имени в проекции
        WITHOUT IF EXISTS o.join_key, o.agg_tov_markup, o.raw_tov_markup
    FROM $input1 AS o
);

$tov = (
    SELECT
        CAST(t.instruct_id AS String) AS join_key,
        t.agg_tov_markup              AS agg_tov_markup,
        t.raw_tov_markup              AS raw_tov_markup
    FROM $input2 AS t
);

-- INNER: задачи без разметки не доезжают. Если нужно сохранить все исходные строки
-- с пустой разметкой — поменяй на LEFT JOIN (orig слева).
INSERT INTO $output1 WITH TRUNCATE
SELECT
    tov.agg_tov_markup AS agg_tov_markup,
    tov.raw_tov_markup AS raw_tov_markup,
    orig.*,
    WITHOUT orig.join_key
FROM $tov AS tov
INNER JOIN $orig AS orig
USING (join_key);
