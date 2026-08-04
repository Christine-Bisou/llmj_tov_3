PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;
DECLARE $output1 AS String;

-- Качество вердикта поверх выхода stars_sbs_v4_merge.sql.
-- Маркеры здесь не считаются: в таблице есть golden_winner, но нет
-- golden_a_checkboxes / golden_b_checkboxes — сравнивать разметку не с чем.
--
-- Метрики:
--   acc          — hard: полное совпадение вердиктов
--   acc_no_draw  — hard на срезе, где золото НЕ ничья
--   soft         — совпадение 1.0; ничью выбрала одна сторона 0.5; иначе 0
--   soft_no_draw — soft на том же срезе
--
-- На выходе две строки:
--   kind = 'model'    — вердикт tov_winner
--   kind = 'baseline' — «бросок монеты» для сравнения.
-- Если модель не обгоняет бейзлайн заметно, разбираться надо не с промтом,
-- а с разметкой.

-- Приводим победителя к 'a' / 'b' / 'draw'.
-- Золото пишет 'answer_b', склейка — 'model_2' и имя сорса в tov_winner_source;
-- 'conflict' (проходы назвали разных победителей) — это несостоявшийся выбор,
-- считаем ничьёй.
$lower = ($v) -> {
    RETURN String::AsciiToLower(String::Strip(COALESCE($v, '')));
};

$canon = ($raw, $sa, $sb) -> {
    RETURN CASE
        WHEN $lower($raw) = ''                                       THEN 'unknown'
        WHEN $lower($raw) IN ('draw', 'tie', 'equal', 'both', 'same',
                              'conflict', 'skip', 'both_bad')        THEN 'draw'
        WHEN $lower($raw) IN ('a', 'answer_a', 'model_1', 'answer_1') THEN 'a'
        WHEN $lower($raw) IN ('b', 'answer_b', 'model_2', 'answer_2') THEN 'b'
        WHEN $lower($sa) != '' AND $lower($raw) = $lower($sa)         THEN 'a'
        WHEN $lower($sb) != '' AND $lower($raw) = $lower($sb)         THEN 'b'
        ELSE 'unknown'
    END;
};

$parsed = (
    SELECT
        $canon(CAST(t.golden_winner AS String),
               CAST(t.source_A AS String),
               CAST(t.source_B AS String)) AS golden,

        $canon(IF($lower(CAST(t.tov_winner AS String)) != '',
                  CAST(t.tov_winner AS String),
                  CAST(t.tov_winner_source AS String)),
               CAST(t.source_A AS String),
               CAST(t.source_B AS String)) AS pred,

        -- воспроизводимый «бросок монеты»: одинаковый между прогонами
        IF(Digest::CityHash(COALESCE(CAST(t.instruct_id AS String), '')) % 2 == 0,
           'a', 'b')                       AS coin
    FROM $input1 AS t
);

-- Строки с нераспознанным вердиктом из метрик выкидываем, но считаем отдельно:
-- иначе они молча уедут в знаменатель и занизят accuracy.
$scored = (
    SELECT
        golden,
        pred,
        coin,
        IF(pred = golden, 1.0, 0.0) AS hard,
        CASE
            WHEN pred = golden                          THEN 1.0
            WHEN pred = 'draw' OR golden = 'draw'       THEN 0.5
            ELSE 0.0
        END AS soft,
        IF(coin = golden, 1.0, 0.0) AS hard_coin,
        CASE
            WHEN coin = golden    THEN 1.0
            WHEN golden = 'draw'  THEN 0.5
            ELSE 0.0
        END AS soft_coin
    FROM $parsed
    WHERE golden != 'unknown' AND pred != 'unknown'
);

-- Счётчики нераспознанных вердиктов: одноклеточный SELECT в переменной YQL
-- отдаёт скаляр, поэтому его можно использовать прямо в проекции ниже.
$rows_golden_unknown = SELECT COUNT(*) FROM $parsed WHERE golden = 'unknown';
$rows_pred_unknown   = SELECT COUNT(*) FROM $parsed WHERE pred = 'unknown';

INSERT INTO $output1 WITH TRUNCATE
SELECT * FROM (
    SELECT
        'model'                                     AS kind,
        COUNT(*)                                    AS cnt,
        COUNT_IF(hard = 1.0)                        AS correct,
        AVG(hard)                                   AS acc,
        AVG(IF(golden != 'draw', hard, NULL))       AS acc_no_draw,
        AVG(soft)                                   AS soft,
        AVG(IF(golden != 'draw', soft, NULL))       AS soft_no_draw,
        COUNT_IF(golden = 'draw')                   AS golden_draws,
        COUNT_IF(pred = 'draw')                     AS pred_draws,
        $rows_golden_unknown                        AS rows_golden_unknown,
        $rows_pred_unknown                          AS rows_pred_unknown
    FROM $scored
)
UNION ALL
SELECT * FROM (
    SELECT
        'baseline'                                  AS kind,
        COUNT(*)                                    AS cnt,
        COUNT_IF(hard_coin = 1.0)                   AS correct,
        AVG(hard_coin)                              AS acc,
        AVG(IF(golden != 'draw', hard_coin, NULL))  AS acc_no_draw,
        AVG(soft_coin)                              AS soft,
        AVG(IF(golden != 'draw', soft_coin, NULL))  AS soft_no_draw,
        COUNT_IF(golden = 'draw')                   AS golden_draws,
        -- монетка ничьих не ставит вообще
        CAST(0 AS Uint64)                           AS pred_draws,
        $rows_golden_unknown                        AS rows_golden_unknown,
        $rows_pred_unknown                          AS rows_pred_unknown
    FROM $scored
);
