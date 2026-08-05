PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;   -- таблица с результатами джаджа (478 строк, колонки for_join НЕТ)
DECLARE $input2 AS String;   -- исходная таблица с for_join (535 строк)
DECLARE $output1 AS String;  -- строки $input2, которых нет в $input1, с for_join
DECLARE $output2 AS String;  -- сводка: сколько всего / сколько сматчилось / сколько потеряно

-- В $input1 нет for_join, а instruct_id там — это сквозная нумерация 1..478 самой
-- таблицы, а не for_join из $input2 (проверено: содержимое строк не совпадает).
-- Поэтому склеиваемся по содержанию пары: вопрос + оба ответа + оба источника.
$key = ($instruct, $a1, $a2, $s1, $s2) -> {
    RETURN Digest::Md5Hex(
        COALESCE(CAST($instruct AS String), '') || '\x01' ||
        COALESCE(CAST($a1 AS String), '')       || '\x01' ||
        COALESCE(CAST($a2 AS String), '')       || '\x01' ||
        COALESCE(CAST($s1 AS String), '')       || '\x01' ||
        COALESCE(CAST($s2 AS String), '')
    );
};

-- ключи, которые джадж реально отработал
$done = (
    SELECT DISTINCT
        $key(instruct, answer_1, answer_2, answer_source_1, answer_source_2) AS k
    FROM $input1
);

$src = (
    SELECT
        $key(instruct, answer_1, answer_2, answer_source_1, answer_source_2) AS k,
        t.*
    FROM $input2 AS t
);

-- строки исходника, для которых в $input1 нет ни одной строки с таким же содержанием
$missing = (
    SELECT
        s.*
    FROM $src AS s
    LEFT ONLY JOIN $done AS d
    ON s.k = d.k
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    for_join,
    instruct_id,
    real_instruct_id,
    instruct,
    answer_source_1,
    answer_source_2,
    family_1,
    family_2,
    answer_1,
    answer_2,
    winner,
    tov_winner
FROM $missing
ORDER BY for_join;

INSERT INTO $output2 WITH TRUNCATE
SELECT
    (SELECT COUNT(*) FROM $input2)              AS rows_input2,
    (SELECT COUNT(*) FROM $input1)              AS rows_input1,
    (SELECT COUNT(*) FROM $src)                 AS rows_src,
    (SELECT COUNT(DISTINCT k) FROM $src)        AS keys_input2,
    (SELECT COUNT(*) FROM $done)                AS keys_input1,
    (SELECT COUNT(*) FROM $missing)             AS rows_missing,
    (SELECT COUNT(DISTINCT k) FROM $missing)    AS keys_missing;

-- ------------------------------------------------------------------
-- Вариант «строка в строку»
--
-- В $input2 есть полные дубли (одна и та же пара вопрос+ответы под разными
-- for_join), а джадж их схлопнул: 535 строк исходника -> 503 уникальных ключа
-- -> 478 строк на выходе. Запрос выше считает потерянными только те строки,
-- содержания которых в $input1 нет вообще. Если нужно добить количество
-- строк до 535 (то есть считать потерянной и вторую копию дубля), замените
-- определение $missing на такое — оно нумерует копии внутри ключа и требует
-- совпадения не только ключа, но и номера копии:
--
-- $src_n = (
--     SELECT s.*, ROW_NUMBER() OVER (PARTITION BY k ORDER BY for_join) AS rn
--     FROM $src AS s
-- );
-- $done_n = (
--     SELECT k, ROW_NUMBER() OVER (PARTITION BY k ORDER BY k) AS rn
--     FROM (
--         SELECT $key(instruct, answer_1, answer_2, answer_source_1, answer_source_2) AS k
--         FROM $input1
--     )
-- );
-- $missing = (
--     SELECT s.*
--     FROM $src_n AS s
--     LEFT ONLY JOIN $done_n AS d
--     ON s.k = d.k AND s.rn = d.rn
-- );
