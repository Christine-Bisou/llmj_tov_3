PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

-- Склейка по паре (instruct, query_1): первый и последний запрос диалога.
-- Ответы первой таблицы идут под номерами 1-4, второй — 5-7.
DECLARE $input1 AS String;   -- model_1..4 / answer_1..4
DECLARE $input2 AS String;   -- model_1..3 / answer_1..3
DECLARE $output1 AS String;
DECLARE $output2 AS String;  -- сколько склеилось

-- answer_* в одной таблице any, в другой string — приводим к одному типу.
$text = ($v) -> { RETURN CAST(Yson::ConvertToString(Yson::From($v)) AS Utf8) };

-- instruct бывает пустым; NULL в ключе не склеился бы сам с собой
$key = ($v) -> { RETURN COALESCE($v, CAST('' AS Utf8)) };

$left = (
    SELECT a.*, $key(a.instruct) AS k_instruct, $key(a.query_1) AS k_query
    FROM $input1 AS a
);

$right = (
    SELECT b.*, $key(b.instruct) AS k_instruct, $key(b.query_1) AS k_query
    FROM $input2 AS b
);

$joined = (
    SELECT
        a.dialog        AS dialog_1,
        b.dialog        AS dialog_2,
        a.instruct      AS instruct,
        a.query_1       AS query_1,

        $text(a.answer_1)   AS answer_1,
        $text(a.answer_2)   AS answer_2,
        $text(a.answer_3)   AS answer_3,
        $text(a.answer_4)   AS answer_4,
        $text(b.answer_1)   AS answer_5,
        $text(b.answer_2)   AS answer_6,
        $text(b.answer_3)   AS answer_7,

        $text(a.model_1)    AS model_1,
        $text(a.model_2)    AS model_2,
        $text(a.model_3)    AS model_3,
        $text(a.model_4)    AS model_4,
        $text(b.model_1)    AS model_5,
        $text(b.model_2)    AS model_6,
        $text(b.model_3)    AS model_7,

        a.k_query           AS k_query
    FROM (SELECT * FROM $left WHERE k_query != '') AS a
    INNER JOIN (SELECT * FROM $right WHERE k_query != '') AS b
        ON a.k_instruct == b.k_instruct AND a.k_query == b.k_query
);

INSERT INTO $output1 WITH TRUNCATE
SELECT j.* WITHOUT if exists j._other, j.k_query
FROM $joined AS j;

$left_rows = (SELECT COUNT(*) FROM $left);
$right_rows = (SELECT COUNT(*) FROM $right);

-- INNER: строка без пары выпадает. Если joined_rows больше joined_keys,
-- значит один и тот же запрос встречается в таблице не один раз.
INSERT INTO $output2 WITH TRUNCATE
SELECT
    $left_rows                  AS left_rows,
    $right_rows                 AS right_rows,
    COUNT(*)                    AS joined_rows,
    COUNT(DISTINCT k_query)     AS joined_keys
FROM $joined;
