PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;
DECLARE $output1 AS String;

-- Качество поверх выхода stars_sbs_v4_merge.sql.
-- Строки маркеров: TP/FP/FN/TN + precision, recall, accuracy, F1.
-- Последние четыре строки — качество вердикта: hard, hard w/o draw,
-- soft, soft w/o draw (kind = 'winner', сортировка ставит их в конец).

-- ========================= МАРКЕРЫ =========================
-- В золоте просто true/false, в предикте — вложенный is_present.
$get_g = ($dict, $key) -> {
    RETURN Yson::LookupBool($dict, $key) ?? false;
};

$get_p = ($dict, $key) -> {
    RETURN Yson::ConvertToBool(Yson::Lookup(Yson::Lookup($dict, $key), 'is_present')) ?? false;
};

-- Маппинг «имя в золоте» -> «имя в предикте».
-- Две правки против прежней версии:
--   * tov_plus_clarity убран — маркера ясности в промте больше нет, строка
--     всегда давала нули и портила средние;
--   * tov_tone_unacceptable теперь смотрит в critical_tone, а не в
--     несуществующий ключ 'unacceptable'.
$get_pairs = ($g, $p) -> {
    RETURN AsList(
        <| marker: "point_bad_intro",              g: $get_g($g, "point_bad_intro"),              p: $get_p($p, "bad_intro") |>,
        <| marker: "point_bad_proactivity",        g: $get_g($g, "point_bad_proactivity"),        p: $get_p($p, "bad_proactivity") |>,
        <| marker: "tov_minus_addressing",         g: $get_g($g, "tov_minus_addressing"),         p: $get_p($p, "inconsistency") |>,
        <| marker: "tov_minus_boundary_violation", g: $get_g($g, "tov_minus_boundary_violation"), p: $get_p($p, "boundaries_violation") |>,
        <| marker: "tov_minus_cliches",            g: $get_g($g, "tov_minus_cliches"),            p: $get_p($p, "template_phrases") |>,
        <| marker: "tov_minus_dry",                g: $get_g($g, "tov_minus_dry"),                p: $get_p($p, "stuffy_bureaucratic") |>,
        <| marker: "tov_minus_language_errors",    g: $get_g($g, "tov_minus_language_errors"),    p: $get_p($p, "language_errors") |>,
        <| marker: "tov_minus_overemotional",      g: $get_g($g, "tov_minus_overemotional"),      p: $get_p($p, "over_emotional") |>,
        <| marker: "tov_plus_empathy",             g: $get_g($g, "tov_plus_empathy"),             p: $get_p($p, "empathy") |>,
        <| marker: "tov_plus_humor",               g: $get_g($g, "tov_plus_humor"),               p: $get_p($p, "humor_metaphors") |>,
        <| marker: "tov_plus_subject",             g: $get_g($g, "tov_plus_subject"),             p: $get_p($p, "subjectivity") |>,
        <| marker: "tov_plus_tone_match",          g: $get_g($g, "tov_plus_tone_match"),          p: $get_p($p, "tone_match") |>,
        <| marker: "tov_tone_unacceptable",        g: $get_g($g, "tov_tone_unacceptable"),        p: $get_p($p, "critical_tone") |>
    );
};

-- A с маркерами первого ответа, B — со вторыми, в одну плоскую таблицу.
$flat_metrics = (
    SELECT
        pair.marker AS marker,
        pair.g      AS golden,
        pair.p      AS pred
    FROM (
        SELECT
            ListExtend(
                $get_pairs(golden_a_checkboxes, markers_1),
                $get_pairs(golden_b_checkboxes, markers_2)
            ) AS pair
        FROM $input1
    )
    FLATTEN BY pair
);

$confusion_matrix = (
    SELECT
        marker,
        SUM(IF(golden AND pred, 1, 0))         AS TP,
        SUM(IF(NOT golden AND pred, 1, 0))     AS FP,
        SUM(IF(golden AND NOT pred, 1, 0))     AS FN,
        SUM(IF(NOT golden AND NOT pred, 1, 0)) AS TN
    FROM $flat_metrics
    GROUP BY marker
);

$marker_rows = (
    SELECT
        'marker'      AS kind,
        marker        AS marker,
        CAST(TP AS Int64) AS TP,
        CAST(FP AS Int64) AS FP,
        CAST(FN AS Int64) AS FN,
        CAST(TN AS Int64) AS TN,

        Just((1.0 * TP) / MAX_OF(1.0, 1.0 * (TP + FP)))                  AS Precision,
        Just((1.0 * TP) / MAX_OF(1.0, 1.0 * (TP + FN)))                  AS Recall,
        Just((1.0 * (TP + TN)) / MAX_OF(1.0, 1.0 * (TP + FP + FN + TN))) AS Accuracy,
        Just((2.0 * TP) / MAX_OF(1.0, 2.0 * TP + FP + FN))               AS F1_Score
    FROM $confusion_matrix
);

-- ========================= ВЕРДИКТ =========================
-- Победитель приводится к 'a' / 'b' / 'draw'.
-- Золото пишет 'answer_b', разметка — 'model_2', склейка — имя сорса; всё это
-- одно и то же. Сравнение регистронезависимое, пробелы по краям срезаются.
-- 'conflict' (проходы назвали разных победителей) считаем ничьёй: как выбор
-- он не состоялся. Долю таких строк отдаём отдельной метрикой ниже.
$lower = ($v) -> {
    RETURN String::AsciiToLower(String::Strip(COALESCE($v, '')));
};

$canon = ($raw, $sa, $sb) -> {
    RETURN CASE
        WHEN $lower($raw) = ''                                          THEN 'unknown'
        WHEN $lower($raw) IN ('draw', 'tie', 'equal', 'both', 'same',
                              'conflict', 'both_bad', 'both_good')      THEN 'draw'
        WHEN $lower($raw) IN ('a', 'answer_a', 'model_1', 'answer_1',
                              'left', 'first', '1')                     THEN 'a'
        WHEN $lower($raw) IN ('b', 'answer_b', 'model_2', 'answer_2',
                              'right', 'second', '2')                   THEN 'b'
        WHEN $lower($sa) != '' AND $lower($raw) = $lower($sa)           THEN 'a'
        WHEN $lower($sb) != '' AND $lower($raw) = $lower($sb)           THEN 'b'
        ELSE 'unknown'
    END;
};

$verdicts = (
    SELECT
        $canon(
            CAST(t.golden_winner AS String),
            CAST(t.source_A AS String),
            CAST(t.source_B AS String)
        ) AS g,
        -- предикт берём из tov_winner (model_1 / model_2 / tie / conflict),
        -- а если его нет — из имени сорса.
        -- Через IF, а не NULLIF: NULLIF появился только в YQL 2025.04.
        $canon(
            IF(
                $lower(CAST(t.tov_winner AS String)) != '',
                CAST(t.tov_winner AS String),
                CAST(t.tov_winner_source AS String)
            ),
            CAST(t.source_A AS String),
            CAST(t.source_B AS String)
        ) AS p,
        COALESCE(CAST(t.tov_winner AS String), '') AS raw_pred
    FROM $input1 AS t
    -- скипы разметчика в качестве не участвуют: там нет золотого вердикта
    WHERE NOT (CAST(t.golden_skip AS Bool) ?? false)
);

-- Строки, где вердикт не распознан с любой стороны, из метрик выкидываем —
-- иначе они молча уедут в знаменатель и занизят accuracy.
$scored = (
    SELECT
        g,
        p,
        raw_pred,
        IF(g = p, 1.0, 0.0) AS hard,
        CASE
            WHEN g = p                                       THEN 1.0
            -- ничью выбрала только одна сторона — половина балла
            WHEN g = 'draw' OR p = 'draw'                    THEN 0.5
            ELSE 0.0
        END AS soft
    FROM $verdicts
    WHERE g != 'unknown' AND p != 'unknown'
);

$winner_rows = (
    SELECT * FROM (
        SELECT
            'winner'                                   AS kind,
            'winner_hard'                              AS marker,
            CAST(SUM(IF(hard = 1.0, 1, 0)) AS Int64)   AS TP,
            CAST(0 AS Int64)                           AS FP,
            CAST(SUM(IF(hard = 0.0, 1, 0)) AS Int64)   AS FN,
            CAST(0 AS Int64)                           AS TN,
            NULL                                       AS Precision,
            NULL                                       AS Recall,
            Just(AVG(hard))                            AS Accuracy,
            NULL                                       AS F1_Score
        FROM $scored
    )
    UNION ALL
    SELECT * FROM (
        SELECT
            'winner'                                   AS kind,
            'winner_hard_wo_draw'                      AS marker,
            CAST(SUM(IF(hard = 1.0, 1, 0)) AS Int64)   AS TP,
            CAST(0 AS Int64)                           AS FP,
            CAST(SUM(IF(hard = 0.0, 1, 0)) AS Int64)   AS FN,
            CAST(0 AS Int64)                           AS TN,
            NULL                                       AS Precision,
            NULL                                       AS Recall,
            Just(AVG(hard))                            AS Accuracy,
            NULL                                       AS F1_Score
        FROM $scored
        WHERE g != 'draw'
    )
    UNION ALL
    SELECT * FROM (
        SELECT
            'winner'                                   AS kind,
            'winner_soft'                              AS marker,
            CAST(SUM(IF(soft = 1.0, 1, 0)) AS Int64)   AS TP,
            CAST(SUM(IF(soft = 0.5, 1, 0)) AS Int64)   AS FP,
            CAST(SUM(IF(soft = 0.0, 1, 0)) AS Int64)   AS FN,
            CAST(0 AS Int64)                           AS TN,
            NULL                                       AS Precision,
            NULL                                       AS Recall,
            Just(AVG(soft))                            AS Accuracy,
            NULL                                       AS F1_Score
        FROM $scored
    )
    UNION ALL
    SELECT * FROM (
        SELECT
            'winner'                                   AS kind,
            'winner_soft_wo_draw'                      AS marker,
            CAST(SUM(IF(soft = 1.0, 1, 0)) AS Int64)   AS TP,
            CAST(SUM(IF(soft = 0.5, 1, 0)) AS Int64)   AS FP,
            CAST(SUM(IF(soft = 0.0, 1, 0)) AS Int64)   AS FN,
            CAST(0 AS Int64)                           AS TN,
            NULL                                       AS Precision,
            NULL                                       AS Recall,
            Just(AVG(soft))                            AS Accuracy,
            NULL                                       AS F1_Score
        FROM $scored
        WHERE g != 'draw'
    )
    UNION ALL
    -- служебная строка: сколько строк дошло до счёта и сколько отвалилось
    -- из-за нераспознанного вердикта. Если TP == 0, метрики выше пустые не
    -- потому что «всё плохо», а потому что считать было не по чему.
    SELECT * FROM (
        SELECT
            'winner'                                                    AS kind,
            'winner_rows_counted'                                       AS marker,
            CAST(SUM(IF(g != 'unknown' AND p != 'unknown', 1, 0)) AS Int64) AS TP,
            CAST(SUM(IF(g = 'unknown', 1, 0)) AS Int64)                 AS FP,
            CAST(SUM(IF(p = 'unknown', 1, 0)) AS Int64)                 AS FN,
            CAST(COUNT(*) AS Int64)                                     AS TN,
            NULL                                                        AS Precision,
            NULL                                                        AS Recall,
            Just(AVG(IF(g != 'unknown' AND p != 'unknown', 1.0, 0.0)))  AS Accuracy,
            NULL                                                        AS F1_Score
        FROM $verdicts
    )
    UNION ALL
    -- служебная строка: как часто прямой и обратный проходы назвали разных
    -- победителей. В accuracy это не входит, но объясняет её просадку.
    SELECT * FROM (
        SELECT
            'winner'                                          AS kind,
            'winner_conflict_share'                           AS marker,
            CAST(SUM(IF(raw_pred = 'conflict', 1, 0)) AS Int64) AS TP,
            CAST(0 AS Int64)                                  AS FP,
            CAST(0 AS Int64)                                  AS FN,
            CAST(0 AS Int64)                                  AS TN,
            NULL                                              AS Precision,
            NULL                                              AS Recall,
            Just(AVG(IF(raw_pred = 'conflict', 1.0, 0.0)))    AS Accuracy,
            NULL                                              AS F1_Score
        FROM $scored
    )
);

-- В строках вердикта TP = совпало, FN = не совпало, FP = засчитано по 0.5
-- (только у soft). Precision / Recall / F1 там не определены — остаются пустыми.
-- В строке winner_rows_counted: TP = сколько строк посчитано, FP = золото не
-- распознано, FN = предикт не распознан, TN = всего строк без скипов.
INSERT INTO $output1 WITH TRUNCATE
SELECT * FROM (
    SELECT * FROM $marker_rows
    UNION ALL
    SELECT * FROM $winner_rows
)
ORDER BY kind, marker;
