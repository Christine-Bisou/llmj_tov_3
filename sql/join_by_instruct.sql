PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;   -- выход extract_query_answers.sql: instruct, answer, vendor, ...
DECLARE $input2 AS String;   -- выход extract_pairwise_answers.sql: instruct, instruct_id, model_1/2, answer_1/2
DECLARE $output1 AS String;  -- склейка: все строки левой таблицы + пара, если нашлась
DECLARE $output2 AS String;  -- диагностика склейки: доля совпавших, дубли ключа

-- Джоин идёт по тексту запроса, а он приезжает из разных пайплайнов
-- (один режет склеенный query, другой берёт готовые сообщения), поэтому
-- ключ нормализуем: схлопываем пробелы и приводим регистр.
$collapse = Re2::Replace(@@\s+@@);

$key = ($s) -> {
    RETURN Unicode::ToLower(
        CAST(String::Strip(CAST($collapse(CAST($s AS Utf8), " ") AS String)) AS Utf8)
    ) ?? CAST('' AS Utf8);
};

$left = (
    SELECT a.*, $key(a.instruct) AS join_key
    FROM $input1 AS a
);

$right = (
    SELECT b.*, $key(b.instruct) AS join_key
    FROM $input2 AS b
    -- пустой instruct склеил бы между собой все строки без запроса
    WHERE $key(b.instruct) != ''
);

$joined = (
    SELECT
        a.* WITHOUT if exists a._other,

        b.instruct_id   AS pair_instruct_id,
        b.model_1       AS model_1,
        b.model_2       AS model_2,
        b.answer_1      AS answer_1,
        b.answer_2      AS answer_2,
        b.dialog        AS pair_dialog,

        IF(b.join_key IS NULL, false, true) AS matched
    FROM $left AS a
    LEFT JOIN $right AS b ON a.join_key == b.join_key
);

INSERT INTO $output1 WITH TRUNCATE
SELECT j.* WITHOUT if exists j.join_key
FROM $joined AS j;

-- Один и тот же запрос может встретиться в правой таблице несколько раз —
-- тогда строка слева размножится. Считаем это здесь, а не молча.
$dup_keys = (
    SELECT COUNT(*)
    FROM (SELECT join_key FROM $right GROUP BY join_key HAVING COUNT(*) > 1)
);

$right_rows = (SELECT COUNT(*) FROM $right);

INSERT INTO $output2 WITH TRUNCATE
SELECT
    COUNT(*)                        AS joined_rows,      -- с учётом размножения
    COUNT(DISTINCT join_key)        AS left_keys,
    COUNT_IF(matched)               AS matched_rows,
    AVG(IF(matched, 1.0, 0.0))      AS match_rate,
    $right_rows                     AS right_rows,
    $dup_keys                       AS right_dup_keys    -- ключей с более чем одной строкой справа
FROM $joined;
