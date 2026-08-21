-- Диагностика join'а: по 20 строк с каждой стороны и все варианты вытащить ключ.
-- Смотрим, в какой колонке лежит человекочитаемый id, а где NULL или бинарь.
DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;

PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.InferSchema = '1';

$left = (
    SELECT
        "1_left"                                                AS side,
        SUBSTRING(CAST(input_meta AS String), 0, 300)           AS raw,
        Yson::ConvertToString(input_meta["instruct_id"])        AS key_yson,
        CAST(input_meta["instruct_id"] AS String)               AS key_cast,
        JSON_VALUE(CAST(CAST(input_meta AS String) AS Json), "$.instruct_id") AS key_json
    FROM $input1
    LIMIT 20
);

$right = (
    SELECT
        "2_right"                                 AS side,
        SUBSTRING(CAST(req_id AS String), 0, 300) AS raw,
        Yson::ConvertToString(req_id)             AS key_yson,
        CAST(req_id AS String)                    AS key_cast,
        CAST(NULL AS String)                      AS key_json
    FROM $input2
    LIMIT 20
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    side,
    raw,
    key_yson,
    key_cast,
    key_json,
    LENGTH(key_yson) AS len_yson,
    LENGTH(key_cast) AS len_cast
FROM (
    SELECT * FROM $left
    UNION ALL
    SELECT * FROM $right
);
