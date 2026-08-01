PRAGMA yt.InferSchema;
PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;

DECLARE $input1 AS String;
DECLARE $output1 AS String;

-- both_bad / tie / skip и пустое значение считаем ничьёй
$norm = ($v) -> {
    RETURN CASE
        WHEN $v IS NULL THEN 'draw'
        WHEN $v IN ('tie', 'both_bad', 'skip', '') THEN 'draw'
        ELSE $v
    END;
};

$d = (
    SELECT
        instruct_id                                                              AS instruct_id,
        $norm(CAST(winner AS String))                                            AS gold,
        $norm(CAST(tov_winner AS String))                                        AS pred,
        $norm(Yson::LookupString(meta_info, 'model_winner_direct'))              AS v_direct,
        $norm(Yson::LookupString(meta_info, 'model_winner_reversed_normalized')) AS v_rev
    FROM $input1
);

$c = (
    SELECT
        gold,
        pred,
        CASE
            WHEN v_direct = v_rev                        THEN '1_проходы_согласны'
            WHEN v_direct = 'draw' OR v_rev = 'draw'     THEN '2_один_проход_ничья'
            ELSE                                              '3_противоречие'
        END AS case_type,
        IF(pred = gold, 1.0, IF(pred = 'draw' OR gold = 'draw', 0.5, 0.0)) AS points
    FROM $d
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    case_type,
    gold,
    COUNT(*)                            AS cnt,
    SUM(points)                         AS points,
    1.0 * SUM(points) / COUNT(*)        AS acc,
    COUNT(*) - SUM(points)              AS lost,
    COUNT_IF(pred = 'draw')             AS pred_draw,
    COUNT_IF(pred != 'draw' AND pred != gold) AS decisive_wrong
FROM $c
GROUP BY case_type, gold
ORDER BY case_type, gold;
