PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;
DECLARE $output1 AS String;   -- точность tov_winner
DECLARE $output2 AS String;   -- точность случайного бейзлайна

-- both_bad / tie / skip / пусто / NULL считаем ничьёй
$norm = ($v) -> {
    RETURN CASE
        WHEN $v IS NULL THEN 'draw'
        WHEN $v IN ('both_bad', 'tie', 'skip', '') THEN 'draw'
        ELSE $v
    END;
};

-- meta_info нет в выведенной схеме (InferSchema='1' смотрит только первую строку),
-- поэтому колонка лежит внутри _other
$mi = ($other, $key) -> {
    RETURN Yson::LookupString(Yson::Lookup($other, 'meta_info'), $key);
};

$base = (
    SELECT
        d.*,
        $norm($mi(d._other, 'model_winner_direct'))              AS v_direct,
        $norm($mi(d._other, 'model_winner_reversed_normalized')) AS v_rev
    FROM $input1 AS d
);

$parsed = (
    SELECT
        b.*,
        $norm(CAST(b.winner AS String))     AS winner_bb_equal_to_draw,
        $norm(CAST(b.tov_winner AS String)) AS tov_winner_norm,
        CASE
            WHEN v_direct = v_rev  THEN v_direct
            WHEN v_direct = 'draw' THEN v_rev
            WHEN v_rev = 'draw'    THEN v_direct
            -- воспроизводимый «бросок монеты»: одинаковый в обоих выходах и между прогонами
            WHEN Digest::CityHash(COALESCE(CAST(b.instruct_id AS String), '')) % 2 == 0
                THEN 'model_1'
            ELSE 'model_2'
        END AS tov_random
    FROM $base AS b
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    COUNT(*)                                                AS cnt,
    COUNT_IF(tov_winner_norm = winner_bb_equal_to_draw)     AS correct,
    1.0 * COUNT_IF(tov_winner_norm = winner_bb_equal_to_draw) / COUNT(*) AS acc,
    1.0 * COUNT_IF(tov_winner_norm = winner_bb_equal_to_draw AND tov_winner_norm != 'draw')
        / COUNT_IF(tov_winner_norm != 'draw')               AS acc_no_draw,
    1.0 * SUM(
        IF(tov_winner_norm = winner_bb_equal_to_draw, 1.0,
           IF(tov_winner_norm = 'draw' OR winner_bb_equal_to_draw = 'draw', 0.5, 0.0))
    ) / COUNT(*)                                            AS acc_draw_05
FROM $parsed;

INSERT INTO $output2 WITH TRUNCATE
SELECT
    COUNT(*)                                                AS cnt,
    COUNT_IF(tov_random = winner_bb_equal_to_draw)          AS correct,
    1.0 * COUNT_IF(tov_random = winner_bb_equal_to_draw) / COUNT(*) AS acc,
    1.0 * COUNT_IF(tov_random = winner_bb_equal_to_draw AND tov_random != 'draw')
        / COUNT_IF(tov_random != 'draw')                    AS acc_no_draw,
    1.0 * SUM(
        IF(tov_random = winner_bb_equal_to_draw, 1.0,
           IF(tov_random = 'draw' OR winner_bb_equal_to_draw = 'draw', 0.5, 0.0))
    ) / COUNT(*)                                            AS acc_draw_05
FROM $parsed;
