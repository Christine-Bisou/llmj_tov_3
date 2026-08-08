PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

-- Проставляет читаемые названия моделям 2, 3 и 4.
-- Остальные колонки, включая model_1 и model_5..7, проезжают без изменений.
DECLARE $input1 AS String;
DECLARE $output1 AS String;

INSERT INTO $output1 WITH TRUNCATE
SELECT
    CAST('QWEN MAX + SYS' AS Utf8)                AS model_2,
    CAST('Deepseek Flash LOW URMH + sys' AS Utf8) AS model_3,
    CAST('Kimi K3 URMH + sys' AS Utf8)            AS model_4,

    -- звёздочка с WITHOUT обязана быть последней в SELECT
    t.* WITHOUT if exists t._other, t.model_2, t.model_3, t.model_4
FROM $input1 AS t;
