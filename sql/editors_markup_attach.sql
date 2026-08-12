DECLARE $input1 AS String;  -- Изначальная таблица
DECLARE $input2 AS String;  -- Выход merge: input-поля + agg_tov_markup / raw_tov_markup
DECLARE $output1 AS String; -- Изначальная таблица целиком + разметка
DECLARE $output2 AS String; -- Только входные поля пайплайна + разметка

PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

-- Джойн один на оба выхода, чтобы условие не разъезжалось между ними.
$joined = (
    SELECT
        orig.*,
        tov.agg_tov_markup AS agg_tov_markup,
        tov.raw_tov_markup AS raw_tov_markup
    FROM $input2 AS tov
    INNER JOIN $input1 AS orig
    ON (
        -- Добавлен CAST(... AS Yson) для аргументов
        Yson::LookupString(CAST(tov.input_meta AS Yson), 'instruct_id') = Yson::LookupString(CAST(orig.input_meta AS Yson), 'instruct_id')
        AND CAST(tov.answers AS String) = CAST(orig.answers AS String)
    )
);

INSERT INTO $output1 WITH TRUNCATE
SELECT *
FROM $joined;

-- Те же строки, но без «хвоста» колонок исходной таблицы: остаётся ровно то,
-- что подаётся на вход пайплайна, и разметка к нему.
INSERT INTO $output2 WITH TRUNCATE
SELECT
    j.answers AS answers,
    j.input_final_messages AS input_final_messages,
    j.input_meta AS input_meta,
    j.input_render_data AS input_render_data,
    j.agg_tov_markup AS agg_tov_markup,
    j.raw_tov_markup AS raw_tov_markup
FROM $joined AS j;
