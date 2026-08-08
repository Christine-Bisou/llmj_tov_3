PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

-- Две выгрузки одной схемы: instruct_id, instruct, dialog, model_1, answer_1.
-- Левая идёт в model_1/answer_1, правая — в model_2/answer_2.
DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;  -- пара ответов на один запрос
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
        b.model_1       AS model_2,
        b.answer_1      AS answer_2
    FROM $left AS a
    INNER JOIN $right AS b ON a.instruct_id == b.instruct_id
);

INSERT INTO $output1 WITH TRUNCATE
SELECT j.* WITHOUT if exists j._other
FROM $joined AS j;

$left_rows = (SELECT COUNT(*) FROM $left);
$right_rows = (SELECT COUNT(*) FROM $right);

-- Если instruct_id в выгрузке не уникален, строка размножится:
-- joined_rows окажется больше joined_ids.
INSERT INTO $output2 WITH TRUNCATE
SELECT
    $left_rows                      AS left_rows,
    $right_rows                     AS right_rows,
    COUNT(*)                        AS joined_rows,
    COUNT(DISTINCT instruct_id)     AS joined_ids
FROM $joined;
