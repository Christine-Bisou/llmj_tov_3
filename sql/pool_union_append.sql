PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;

DECLARE $input1 AS String;   -- существующий пул: схема как в $output1
DECLARE $input2 AS String;   -- добавляемая таблица: все колонки Yson, ответы A/B
DECLARE $output1 AS String;  -- объединённый пул

-- проставляем добавляемым строкам, своей разметочной даты у них нет
$markup_dt   = "2026-06-02";
$approved_by = "management";

-- этих полей во второй таблице нет, задаём здесь
$pool_id   = "";
$pool_type = "";

-- Yson-скаляр в обычную строку; пусто вместо NULL, чтобы колонка осталась
-- необязательной String, как в существующем пуле
$str = ($y) -> {
    RETURN Yson::ConvertToString($y) ?? "";
};

-- A -> answer_1, B -> answer_2.
-- Вердикт в `golden winner` может быть именем источника либо меткой стороны —
-- метку разворачиваем в источник, чтобы winner_source везде значил одно и то же
$winner_source = ($w, $sa, $sb) -> {
    RETURN CASE
        WHEN $w IN ("A", "a", "answer_A", "model_1") THEN $sa
        WHEN $w IN ("B", "b", "answer_B", "model_2") THEN $sb
        ELSE $w
    END;
};

-- Yson-диалог в List<Struct<content:Utf8, role:Utf8>>.
-- Разбираем поштучно, а не Yson::ConvertTo целиком: в разметочных диалогах
-- у сообщений бывают лишние поля, на них строгая конверсия падает
$dialog = ($y) -> {
    RETURN ListMap(
        Yson::ConvertToList($y),
        ($m) -> {
            RETURN AsStruct(
                CAST(Yson::ConvertToString(Yson::Lookup($m, "content")) AS Utf8) ?? ""u AS content,
                CAST(Yson::ConvertToString(Yson::Lookup($m, "role"))    AS Utf8) ?? ""u AS role
            );
        }
    );
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
    $str(answer_A)              AS answer_1,
    $str(answer_B)              AS answer_2,
    $str(source_A)              AS answer_source_1,
    $str(source_B)              AS answer_source_2,
    $approved_by                AS approved_by,
    ""                          AS comment,
    $dialog(dialog)             AS dialog,
    $str(instruct_id)           AS instruct_id,
    $markup_dt                  AS last_markup_dt,
    $markup_dt                  AS original_markup_dt,
    $pool_id                    AS pool_id,
    $pool_type                  AS pool_type,
    $str(instruct_id)           AS real_instruct_id,
    $winner_source(
        $str(`golden winner`),
        $str(source_A),
        $str(source_B)
    )                           AS winner_source
FROM $input2;
