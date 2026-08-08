PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

-- Проставляет читаемые названия всем семи моделям.
-- Остальные колонки проезжают без изменений.
DECLARE $input1 AS String;
DECLARE $output1 AS String;

INSERT INTO $output1 WITH TRUNCATE
SELECT
    CAST('prod' AS Utf8)                            AS model_1,
    CAST('Qwen MAX' AS Utf8)                        AS model_2,
    CAST('Deepseek Flash LOW' AS Utf8)              AS model_3,
    CAST('Kimi K3' AS Utf8)                         AS model_4,
    CAST('DS Instant + Thinking + Search' AS Utf8)  AS model_5,
    CAST('Gemini 3.5 Flash' AS Utf8)                AS model_6,
    CAST('ChatGPT Medium' AS Utf8)                  AS model_7,

    -- звёздочка с WITHOUT обязана быть последней в SELECT
    t.* WITHOUT if exists
        t._other,
        t.model_1, t.model_2, t.model_3, t.model_4,
        t.model_5, t.model_6, t.model_7
FROM $input1 AS t;
