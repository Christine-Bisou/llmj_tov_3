PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;
DECLARE $output1 AS String;

-- Точность вердикта поверх выхода stars_sbs_v4_merge.sql. Одна строка:
--   cnt          — сколько строк посчитано
--   correct      — сколько вердиктов совпало с золотом
--   acc          — доля совпадений
--   acc_no_draw  — доля совпадений среди строк, где МОДЕЛЬ не поставила ничью
--   acc_draw_05  — то же, но ничья одной стороны засчитывается за половину

-- Приводим победителя к 'a' / 'b' / 'draw': золото пишет 'answer_b',
-- склейка — 'model_2', в tov_winner_source лежит имя сорса.
-- 'conflict' (прямой и обратный проход назвали разных победителей) —
-- несостоявшийся выбор, считаем ничьёй.
$lower = ($v) -> {
    RETURN String::AsciiToLower(String::Strip(COALESCE($v, '')));
};

$canon = ($raw, $sa, $sb) -> {
    RETURN CASE
        WHEN $lower($raw) = ''                                        THEN 'unknown'
        WHEN $lower($raw) IN ('draw', 'tie', 'equal', 'both', 'same',
                              'conflict', 'skip', 'both_bad')         THEN 'draw'
        WHEN $lower($raw) IN ('a', 'answer_a', 'model_1', 'answer_1') THEN 'a'
        WHEN $lower($raw) IN ('b', 'answer_b', 'model_2', 'answer_2') THEN 'b'
        WHEN $lower($sa) != '' AND $lower($raw) = $lower($sa)         THEN 'a'
        WHEN $lower($sb) != '' AND $lower($raw) = $lower($sb)         THEN 'b'
        ELSE 'unknown'
    END;
};

-- Строки, где вердикт не распознан ни с одной стороны, в метрики не идут:
-- иначе они молча уедут в знаменатель и занизят accuracy.
$parsed = (
    SELECT
        $canon(CAST(t.golden_winner AS String),
               CAST(t.source_A AS String),
               CAST(t.source_B AS String)) AS golden,

        $canon(IF($lower(CAST(t.tov_winner AS String)) != '',
                  CAST(t.tov_winner AS String),
                  CAST(t.tov_winner_source AS String)),
               CAST(t.source_A AS String),
               CAST(t.source_B AS String)) AS pred
    FROM $input1 AS t
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    COUNT(*)                                                        AS cnt,
    COUNT_IF(pred = golden)                                         AS correct,
    1.0 * COUNT_IF(pred = golden) / COUNT(*)                        AS acc,
    1.0 * COUNT_IF(pred = golden AND pred != 'draw')
        / COUNT_IF(pred != 'draw')                                  AS acc_no_draw,
    1.0 * SUM(IF(pred = golden, 1.0,
                 IF(pred = 'draw' OR golden = 'draw', 0.5, 0.0)))
        / COUNT(*)                                                  AS acc_draw_05
FROM $parsed
WHERE golden != 'unknown' AND pred != 'unknown';
