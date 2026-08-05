DECLARE $input1 AS String;   -- выход склейки: golden_winner, tov_winner, answer_source_1/2, family_1/2
DECLARE $output1 AS String;

PRAGMA yt.InferSchema;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yson.DisableStrict;

-- нижний регистр + обрезка пробелов, NULL -> ''
$norm = ($x) -> {
    RETURN Unicode::ToLower(CAST(String::Strip(COALESCE(CAST($x AS String?), "")) AS Utf8));
};

-- Золото и предсказание записаны по-разному: в golden_winner лежит ИМЯ ИСТОЧНИКА
-- (та же строка, что в answer_source_1/2), а в tov_winner — model_1 / model_2.
-- Поэтому обе стороны приводим к одной шкале model_1 / model_2 / draw, иначе
-- сравнение строк даёт ноль на всех строках.
--
-- Вся семья ничьих схлопывается в draw:
--   tie      — джадж честно назвал ничью;
--   conflict — прямой и обратный проходы назвали РАЗНЫХ победителей, это
--              не ничья по существу, а отказ джаджа; считаем как ничью,
--              но отдельно считаем их количество колонкой conflict_cnt;
--   both_bad / skip — из ручной разметки.
-- Пустая строка означает «нет значения»: такие строки в метрику не идут
-- и видны в skipped_model / skipped_golden.
$side = ($w, $s1, $s2) -> {
    RETURN CASE
        WHEN $w == ""                                             THEN ""
        WHEN $w IN ("draw", "tie", "conflict", "both_bad", "skip") THEN "draw"
        WHEN $w IN ("model_1", "model_2")                         THEN $w
        WHEN $w == $s1                                            THEN "model_1"
        WHEN $w == $s2                                            THEN "model_2"
        -- имя, которого нет среди источников этой строки: молча засчитать
        -- его ошибкой нельзя, поэтому строка выпадает как неразмеченная
        ELSE ""
    END;
};

-- Полбалла за «одна сторона ничья, другая назвала победителя»:
-- это не такая же ошибка, как назвать победителем проигравшего.
$score_half = ($golden, $model) -> {
    RETURN CASE
        WHEN $golden == $model                        THEN 1.0
        WHEN $golden == "draw" OR $model == "draw"    THEN 0.5
        ELSE 0.0
    END;
};

$score_strict = ($golden, $model) -> {
    RETURN IF($golden == $model, 1.0, 0.0);
};

$scored =
SELECT
    CASE
        WHEN f1 == "VLM"   OR f2 == "VLM"   THEN "vlm"
        WHEN f1 == "Neuro" OR f2 == "Neuro" THEN "neuro"
        ELSE "other"
    END AS family,
    g,
    m,
    m_raw,
    IF(g != "" AND m != "", $score_half(g, m),   Nothing(Double?)) AS s_half,
    IF(g != "" AND m != "", $score_strict(g, m), Nothing(Double?)) AS s_strict
FROM (
    SELECT
        f1,
        f2,
        m_raw,
        $side(g_raw, s1, s2) AS g,
        $side(m_raw, s1, s2) AS m
    FROM (
        SELECT
            CAST(family_1 AS Utf8?) AS f1,
            CAST(family_2 AS Utf8?) AS f2,
            $norm(golden_winner)    AS g_raw,
            $norm(tov_winner)       AS m_raw,
            $norm(answer_source_1)  AS s1,
            $norm(answer_source_2)  AS s2
        FROM $input1
    )
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    family,
    AVG(s_half)                  AS quality_with_half,
    AVG(s_strict)                AS quality_strict,
    COUNT_IF(s_half IS NOT NULL) AS cnt,
    COUNT(*)                     AS rows_total,
    COUNT_IF(m == "")            AS skipped_model,
    COUNT_IF(g == "")            AS skipped_golden,
    -- сколько ничьих джаджа на самом деле развал проходов, а не решение
    COUNT_IF(m_raw == "conflict") AS conflict_cnt,
    COUNT_IF(m == "draw")         AS draw_predicted
FROM $scored
WHERE family != "other"
GROUP BY family

UNION ALL

SELECT
    "all" AS family,
    AVG(s_half)                  AS quality_with_half,
    AVG(s_strict)                AS quality_strict,
    COUNT_IF(s_half IS NOT NULL) AS cnt,
    COUNT(*)                     AS rows_total,
    COUNT_IF(m == "")            AS skipped_model,
    COUNT_IF(g == "")            AS skipped_golden,
    COUNT_IF(m_raw == "conflict") AS conflict_cnt,
    COUNT_IF(m == "draw")         AS draw_predicted
FROM $scored;
