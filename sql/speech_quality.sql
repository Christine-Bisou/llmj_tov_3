PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

DECLARE $input1 AS String;   -- прогон: склейка, markers_N_flags, instruct_id_real
DECLARE $input2 AS String;   -- золото: instruct_id + target_markup.verdict
DECLARE $input3 AS String;   -- доп. джадж по речевым: dst + instruct_id
DECLARE $output1 AS String;

$marker = 'language_errors';

$flag = ($flags, $name) -> {
    RETURN Yson::ConvertToBool(Yson::Lookup($flags, $name)) ?? false;
};

-- ===================== ДОП. ДЖАДЖ ПО РЕЧЕВЫМ =====================
-- В dst лежит ответ джаджа строкой:
--   {model_N_scan: "...", model_N_markers: {language_errors: {is_present, explanation}}}
-- Ответы не переставлены: model_1 — это answer_1, model_2 — answer_2.
$script = @@#py
import json
import cyson


def process_json(s):
    """
    (String?) -> Yson?
    """
    if s is None:
        return None

    if isinstance(s, bytes):
        s = s.decode('utf-8', errors='ignore')
    else:
        s = str(s)

    s = s.strip()
    if s.startswith('```json'):
        s = s[7:]
    elif s.startswith('```'):
        s = s[3:]
    if s.endswith('```'):
        s = s[:-3]
    s = s.strip()

    i, j = s.find('{'), s.rfind('}')
    if i != -1 and j != -1 and j > i:
        s = s[i:j + 1]

    try:
        return cyson.dumps(json.loads(s, strict=False))
    except Exception:
        return None
@@;

$process_json = Python3::process_json($script);

$ext_on = ($y, $markers_key) -> {
    RETURN Yson::ConvertToBool(
        Yson::Lookup(Yson::Lookup(Yson::Lookup($y, $markers_key), $marker), 'is_present')
    ) ?? false;
};

$extra_yson = (
    SELECT
        COALESCE(CAST(e.instruct_id AS String), '') AS instruct_id,
        $process_json(CAST(e.dst AS String))        AS y
    FROM $input3 AS e
);

-- GROUP BY схлопывает дубли по ключу, если джадж отработал по строке дважды:
-- маркер берём по ИЛИ, поэтому MAX по 0/1.
$extra = (
    SELECT
        instruct_id                                       AS instruct_id,
        MAX(CAST($ext_on(y, 'model_1_markers') AS Int32)) > 0 AS e1,
        MAX(CAST($ext_on(y, 'model_2_markers') AS Int32)) > 0 AS e2
    FROM $extra_yson
    WHERE instruct_id != ''
    GROUP BY instruct_id
);

-- ===================== ПРОГОН =====================
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

-- Подмена: нашёл доп. джадж — ставим true. Снимать маркер он не может.
-- LEFT JOIN: где доп. джаджа нет, остаётся то, что было.
$pred_fixed = (
    SELECT
        p.instruct_id                        AS instruct_id,
        p.ok                                 AS ok,
        p.p1 OR COALESCE(x.e1, false)        AS p1,
        p.p2 OR COALESCE(x.e2, false)        AS p2,
        -- сколько строк вообще нашлось в доп. джадже: если тут ноль,
        -- значит склеились не по тому ключу, а не «джадж ничего не нашёл»
        IF(x.instruct_id IS NULL, 0, 1)      AS extra_matched,
        IF(COALESCE(x.e1, false) AND NOT p.p1, 1, 0)
            + IF(COALESCE(x.e2, false) AND NOT p.p2, 1, 0) AS extra_added
    FROM $pred AS p
    LEFT JOIN $extra AS x
    USING (instruct_id)
);

-- ===================== ЗОЛОТО =====================
-- verdict = 0 — речевых ошибок нет, 1 и выше — есть.
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
    SELECT
        p.ok AS ok, p.p1 AS p1, p.p2 AS p2,
        p.extra_matched AS extra_matched,
        p.extra_added   AS extra_added,
        g.gs_language AS gs_language
    FROM $pred_fixed AS p
    INNER JOIN $gold_ AS g
    USING (instruct_id)
);

-- Две стороны через UNION ALL: одна строка на ответ, как и раньше.
-- Колонки в ветках названы одинаково — YQL сшивает UNION ALL по именам.
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
    SELECT
        COUNT(*)                        AS pairs_total,
        SUM(IF(p1 != p2, 1, 0))         AS pairs_sides_disagree,
        SUM(extra_matched)              AS extra_matched_rows,
        SUM(extra_added)                AS extra_added_true
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
    (1.0 * k.pairs_sides_disagree) / MAX_OF(1.0, 1.0 * k.pairs_total) AS sides_disagree_rate,
    -- про подмену: сколько строк нашлось в доп. джадже и сколько маркеров он добавил
    k.extra_matched_rows AS extra_matched_rows,
    k.extra_added_true   AS extra_added_true
FROM $confusion AS c
CROSS JOIN $consistency AS k;
