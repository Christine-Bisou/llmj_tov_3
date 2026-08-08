PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

-- Две таблицы пар на одних и тех же запросах: model_1/2 в первой,
-- model_3/4 во второй. Склеиваем в один ряд из четырёх ответов.
DECLARE $input1 AS String;   -- instruct_id, instruct, dialog, model_1/2, answer_1/2
DECLARE $input2 AS String;   -- instruct_id, instruct, dialog, model_3/4, answer_3/4
DECLARE $output1 AS String;  -- четыре ответа на один запрос
DECLARE $output2 AS String;  -- сколько склеилось

$left = (
    SELECT a.*
    FROM $input1 AS a
    WHERE a.instruct_id IS NOT NULL
);

$right = (
    SELECT b.*
    FROM $input2 AS b
    WHERE b.instruct_id IS NOT NULL
);

$joined = (
    SELECT
        a.instruct_id   AS instruct_id,
        -- instruct и dialog одинаковые с обеих сторон, оставляем один
        a.instruct      AS instruct,
        a.dialog        AS dialog,

        a.model_1       AS model_1,
        a.answer_1      AS answer_1,
        a.model_2       AS model_2,
        a.answer_2      AS answer_2,
        b.model_3       AS model_3,
        b.answer_3      AS answer_3,
        b.model_4       AS model_4,
        b.answer_4      AS answer_4
    FROM $left AS a
    INNER JOIN $right AS b ON a.instruct_id == b.instruct_id
);

INSERT INTO $output1 WITH TRUNCATE
SELECT j.* WITHOUT if exists j._other
FROM $joined AS j;

$left_rows = (SELECT COUNT(*) FROM $left);
$right_rows = (SELECT COUNT(*) FROM $right);

-- INNER: строка без пары со второй стороны выпадает. Сколько именно —
-- видно по left_rows/right_rows против joined_rows. Если instruct_id внутри
-- таблицы не уникален, joined_rows окажется больше joined_ids.
INSERT INTO $output2 WITH TRUNCATE
SELECT
    $left_rows                      AS left_rows,
    $right_rows                     AS right_rows,
    COUNT(*)                        AS joined_rows,
    COUNT(DISTINCT instruct_id)     AS joined_ids
FROM $joined;
