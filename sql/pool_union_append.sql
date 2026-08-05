PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;

DECLARE $input1 AS String;   -- существующий пул: схема как в $output1
DECLARE $input2 AS String;   -- добавляемая таблица: вердикт лежит в колонке golden
DECLARE $output1 AS String;  -- объединённый пул

-- проставляем добавляемым строкам, у них своей разметочной даты нет
$markup_dt   = "2026-06-02";
$approved_by = "management";

-- в добавляемой таблице этих полей нет, задаём здесь
$pool_id   = "";
$pool_type = "";

-- golden может быть как именем источника, так и model_1 / model_2 —
-- второй случай разворачиваем в источник, чтобы колонка везде значила одно и то же
$winner_source = ($w, $s1, $s2) -> {
    RETURN CASE
        WHEN $w IS NULL      THEN ""
        WHEN $w = "model_1"  THEN $s1
        WHEN $w = "model_2"  THEN $s2
        ELSE $w
    END;
};

INSERT INTO $output1 WITH TRUNCATE

SELECT
    answer_1,
    answer_2,
    answer_source_1,
    answer_source_2,
    approved_by,
    comment,
    dialog,
    instruct_id,
    last_markup_dt,
    original_markup_dt,
    pool_id,
    pool_type,
    real_instruct_id,
    winner_source
FROM $input1

UNION ALL

SELECT
    CAST(answer_1        AS String)              AS answer_1,
    CAST(answer_2        AS String)              AS answer_2,
    CAST(answer_source_1 AS String)              AS answer_source_1,
    CAST(answer_source_2 AS String)              AS answer_source_2,
    $approved_by                                 AS approved_by,
    ""                                           AS comment,
    dialog                                       AS dialog,
    CAST(instruct_id     AS String)              AS instruct_id,
    $markup_dt                                   AS last_markup_dt,
    $markup_dt                                   AS original_markup_dt,
    $pool_id                                     AS pool_id,
    $pool_type                                   AS pool_type,
    CAST(instruct_id     AS String)              AS real_instruct_id,
    $winner_source(
        CAST(golden          AS String),
        CAST(answer_source_1 AS String),
        CAST(answer_source_2 AS String)
    )                                            AS winner_source
FROM $input2;
