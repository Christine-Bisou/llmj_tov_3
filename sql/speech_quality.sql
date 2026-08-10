PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

DECLARE $input1 AS String;   -- прогон: markers_N_flags, instruct_id_real, parsed_ok
DECLARE $input2 AS String;   -- золото: instruct_id + target_markup.verdict
DECLARE $output1 AS String;

$marker = 'language_errors';

$flag = ($flags, $name) -> {
    RETURN Yson::ConvertToBool(Yson::Lookup($flags, $name)) ?? false;
};

-- Речевые в markers_N_flags уже с добором доп. джаджа: маркер там ставится,
-- если его увидел хотя бы один проход ИЛИ доп. джадж. Подмена сделана на
-- склейке, здесь ничего добирать не надо — считаем то, что пришло.

-- Строки без instruct_id_real джойнить не по чему; COALESCE снимает Optional,
-- чтобы ключи с обеих сторон были одного типа String.
$pred = (
    SELECT
        COALESCE(CAST(p.instruct_id_real AS String), '') AS instruct_id,
        $flag(p.markers_1_flags, $marker)                AS p1,
        $flag(p.markers_2_flags, $marker)                AS p2,
        p.parsed_ok                                      AS ok
    FROM $input1 AS p
    WHERE p.instruct_id_real IS NOT NULL
);

-- Золото: verdict = 0 — речевых ошибок нет, 1 и выше — есть.
$gold = (
    SELECT
        g.instruct_id                                    AS instruct_id,
        Yson::ConvertToInt64(g.target_markup['verdict']) AS verdict
    FROM $input2 AS g
);

$gold_ = (
    SELECT instruct_id, verdict >= 1 AS gs_language
    FROM $gold
    WHERE verdict IS NOT NULL
);

$joined = (
    SELECT p.ok AS ok, p.p1 AS p1, p.p2 AS p2, g.gs_language AS gs_language
    FROM $pred AS p
    INNER JOIN $gold_ AS g
    USING (instruct_id)
);

-- Одна строка на ответ: сторона A и сторона B через UNION ALL.
-- Списком записей с FLATTEN BY тут не обойтись — короткую запись структуры
-- <| ... |> парсер не берёт, а UNION ALL даёт ровно то же самое.
-- Колонки в ветках названы одинаково: UNION ALL в YQL сшивает по именам.
$flat = (
    SELECT ok AS ok, gs_language AS golden, p1 AS pred FROM $joined
    UNION ALL
    SELECT ok AS ok, gs_language AS golden, p2 AS pred FROM $joined
);

$confusion = (
    SELECT
        SUM(IF(golden AND pred, 1, 0))         AS TP,
        SUM(IF(NOT golden AND pred, 1, 0))     AS FP,
        SUM(IF(golden AND NOT pred, 1, 0))     AS FN,
        SUM(IF(NOT golden AND NOT pred, 1, 0)) AS TN,
        COUNT(*)                               AS answers_total,
        SUM(IF(NOT ok, 1, 0))                  AS parse_failed
    FROM $flat
);

$consistency = (
    SELECT COUNT(*) AS pairs_total, SUM(IF(p1 != p2, 1, 0)) AS pairs_sides_disagree
    FROM $joined
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    'language_errors_vs_gs' AS marker,
    c.TP AS TP, c.FP AS FP, c.FN AS FN, c.TN AS TN,
    (1.0 * c.TP) / MAX_OF(1.0, 1.0 * (c.TP + c.FP))            AS Precision,
    (1.0 * c.TP) / MAX_OF(1.0, 1.0 * (c.TP + c.FN))            AS Recall,
    (1.0 * (c.TP + c.TN)) / MAX_OF(1.0, 1.0 * c.answers_total) AS Accuracy,
    (2.0 * c.TP) / MAX_OF(1.0, 2.0 * c.TP + c.FP + c.FN)       AS F1_Score,
    c.TP + c.FN                                                AS golden_positives,
    c.TP + c.FP                                                AS predicted_positives,
    (1.0 * (c.TP + c.FN)) / MAX_OF(1.0, 1.0 * c.answers_total) AS golden_rate,
    (1.0 * (c.TP + c.FP)) / MAX_OF(1.0, 1.0 * c.answers_total) AS pred_rate,
    c.answers_total AS answers_total,
    c.parse_failed  AS parse_failed,
    k.pairs_total          AS pairs_total,
    k.pairs_sides_disagree AS pairs_sides_disagree,
    (1.0 * k.pairs_sides_disagree) / MAX_OF(1.0, 1.0 * k.pairs_total) AS sides_disagree_rate
FROM $confusion AS c
CROSS JOIN $consistency AS k;
