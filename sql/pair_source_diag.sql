DECLARE $input1 AS String;
DECLARE $output1 AS String;

PRAGMA yt.InferSchema = '1';
PRAGMA Yson.AutoConvert;

-- Кто на самом деле различает две стороны пары: answer_source_* или family_*.
-- Читаются только строковые колонки, диалоги не трогаются.
INSERT INTO $output1 WITH TRUNCATE
SELECT
    COALESCE(answer_source_1, "<null>") AS answer_source_1,
    COALESCE(answer_source_2, "<null>") AS answer_source_2,
    CAST(COALESCE(family_1, "<null>"u) AS String) AS family_1,
    CAST(COALESCE(family_2, "<null>"u) AS String) AS family_2,
    COUNT(*) AS rows_cnt,
    COUNT_IF(COALESCE(answer_source_1, "") == COALESCE(answer_source_2, "")) AS same_source,
    COUNT_IF(COALESCE(family_1, ""u) == COALESCE(family_2, ""u)) AS same_family,
    COUNT_IF(COALESCE(answer_1, "") == COALESCE(answer_2, "")) AS same_answer,
    MIN(instruct_id) AS sample_instruct_id
FROM $input1
GROUP BY
    COALESCE(answer_source_1, "<null>"),
    COALESCE(answer_source_2, "<null>"),
    CAST(COALESCE(family_1, "<null>"u) AS String),
    CAST(COALESCE(family_2, "<null>"u) AS String)
ORDER BY rows_cnt DESC;
