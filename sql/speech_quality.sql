PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

DECLARE $input1 AS String;   -- прогон: склейка второго этапа, markers_N_flags, instruct_id_real
DECLARE $input2 AS String;   -- золото: instruct_id + target_markup.verdict
DECLARE $input3 AS String;   -- доп. джадж по речевым: dst, for_join, instruct_id
DECLARE $output1 AS String;  -- метрика: три варианта предсказания в одной таблице
DECLARE $output2 AS String;  -- построчные расхождения на ручной просмотр

$marker = 'language_errors';

-- Сколько символов ответа тащить в выгрузку расхождений
$answer_cut = 400;

$flag = ($flags, $name) -> {
    RETURN Yson::ConvertToBool(Yson::Lookup($flags, $name)) ?? false;
};

-- ===================== ДОП. ДЖАДЖ ПО РЕЧЕВЫМ =====================
-- Выход джаджа лежит в dst строкой, внутри:
--   {model_N_scan: "...", model_N_markers: {language_errors: {is_present, explanation}}}
-- model_1 — это answer_1 (сторона A), model_2 — answer_2 (сторона B):
-- джадж гоняется в прямом порядке, переставлять ничего не надо.
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

$ext_why = ($y, $markers_key) -> {
    RETURN Yson::LookupString(
        Yson::Lookup(Yson::Lookup($y, $markers_key), $marker), 'explanation'
    ) ?? '';
};

-- Разбор dst отдельным шагом: Python-UDF дорогая, звать её по разу на каждое
-- поле незачем.
$extra_yson = (
    SELECT
        COALESCE(CAST(e.instruct_id AS String), '')  AS k_id,
        COALESCE(CAST(e.for_join AS String), '')     AS k_join,
        $process_json(CAST(e.dst AS String))         AS y
    FROM $input3 AS e
);

$extra_flat = (
    SELECT
        k_id                              AS k_id,
        k_join                            AS k_join,
        $ext_on(y,  'model_1_markers')    AS ea,
        $ext_on(y,  'model_2_markers')    AS eb,
        $ext_why(y, 'model_1_markers')    AS ea_why,
        $ext_why(y, 'model_2_markers')    AS eb_why,
        IF(y IS NULL, 1, 0)               AS bad_json
    FROM $extra_yson
);

-- Ключ в прогоне и в доп. джадже назван по-разному, и заранее не известно,
-- какой из них сквозной: в прогоне есть instruct_id_real (строка) и
-- instruct_id (нумерация строк), в доп. джадже — instruct_id (строка) и
-- for_join. Поэтому джойним обоими способами, а в метрику кладём счётчики
-- совпадений: если сквозным оказался другой ключ, это видно по нулю, а не
-- по тихо пустой подмене.
--
-- Группировка заодно схлопывает дубли по ключу: маркер по стороне берём по
-- ИЛИ, поэтому MAX по 0/1.
$extra_by_id = (
    SELECT
        k_id                            AS k,
        MAX(CAST(ea AS Int32)) > 0      AS ea,
        MAX(CAST(eb AS Int32)) > 0      AS eb,
        MAX(ea_why)                     AS ea_why,
        MAX(eb_why)                     AS eb_why
    FROM $extra_flat
    WHERE k_id != ''
    GROUP BY k_id
);

$extra_by_join = (
    SELECT
        k_join                          AS k,
        MAX(CAST(ea AS Int32)) > 0      AS ea,
        MAX(CAST(eb AS Int32)) > 0      AS eb,
        MAX(ea_why)                     AS ea_why,
        MAX(eb_why)                     AS eb_why
    FROM $extra_flat
    WHERE k_join != ''
    GROUP BY k_join
);

-- ===================== ПРОГОН =====================
-- Строки без instruct_id_real джойнить не по чему; COALESCE снимает Optional,
-- чтобы ключи с обеих сторон были одного типа String.
$pred = (
    SELECT
        COALESCE(CAST(p.instruct_id_real AS String), '') AS instruct_id,
        COALESCE(CAST(p.instruct_id AS String), '')      AS k_num,
        $flag(p.markers_1_flags, $marker)                AS p1,
        $flag(p.markers_2_flags, $marker)                AS p2,
        p.parsed_ok                                      AS ok,
        COALESCE(CAST(p.answer_1 AS String), '')         AS answer_1,
        COALESCE(CAST(p.answer_2 AS String), '')         AS answer_2,
        COALESCE(CAST(p.answer_source_1 AS String), '')  AS source_1,
        COALESCE(CAST(p.answer_source_2 AS String), '')  AS source_2
    FROM $input1 AS p
    WHERE p.instruct_id_real IS NOT NULL
);

-- Подмена: маркер речевых ставим, если его нашли проходы ИЛИ доп. джадж.
-- Обратно доп. джадж не работает — снять маркер, который увидели проходы,
-- он не может, это добор полноты, а не вето.
$pred_extra = (
    SELECT
        p.instruct_id AS instruct_id,
        p.ok          AS ok,
        p.p1          AS p1,
        p.p2          AS p2,
        p.answer_1    AS answer_1,
        p.answer_2    AS answer_2,
        p.source_1    AS source_1,
        p.source_2    AS source_2,

        COALESCE(a.ea, b.ea, false)  AS e1,
        COALESCE(a.eb, b.eb, false)  AS e2,
        COALESCE(a.ea_why, b.ea_why, '') AS e1_why,
        COALESCE(a.eb_why, b.eb_why, '') AS e2_why,

        IF(a.k IS NOT NULL, 1, 0) AS hit_by_id,
        IF(b.k IS NOT NULL, 1, 0) AS hit_by_join,
        IF(a.k IS NULL AND b.k IS NULL, 1, 0) AS extra_missing
    FROM $pred AS p
    LEFT JOIN $extra_by_id   AS a ON p.instruct_id == a.k
    LEFT JOIN $extra_by_join AS b ON p.k_num       == b.k
);

-- ===================== ЗОЛОТО =====================
-- verdict = 0 — речевых ошибок нет, 1 и выше — есть.
$gold = (
    SELECT
        g.instruct_id                                    AS instruct_id,
        Yson::ConvertToInt64(g.target_markup['verdict']) AS verdict
    FROM $input2 AS g
);

-- COALESCE снимает Optional: дальше флаг ходит по IF и CASE, а туда
-- Optional<Bool> лучше не подавать.
$gold_ = (
    SELECT instruct_id, COALESCE(verdict >= 1, false) AS gs_language
    FROM $gold
    WHERE verdict IS NOT NULL
);

$joined = (
    SELECT
        p.instruct_id AS instruct_id,
        p.ok AS ok,
        p.p1 AS p1, p.p2 AS p2,
        p.e1 AS e1, p.e2 AS e2,
        p.e1_why AS e1_why, p.e2_why AS e2_why,
        -- итог подмены
        p.p1 OR p.e1 AS m1,
        p.p2 OR p.e2 AS m2,
        p.hit_by_id AS hit_by_id,
        p.hit_by_join AS hit_by_join,
        p.extra_missing AS extra_missing,
        p.answer_1 AS answer_1, p.answer_2 AS answer_2,
        p.source_1 AS source_1, p.source_2 AS source_2,
        -- золото пообъектное: verdict стоит на задаче целиком, поэтому обе
        -- стороны сверяются с одним и тем же флагом. Так считалось и раньше,
        -- менять нельзя — иначе цифры перестанут быть сравнимыми
        g.gs_language AS gs_language
    FROM $pred_extra AS p
    INNER JOIN $gold_ AS g
    USING (instruct_id)
);

-- Три варианта предсказания в одной таблице: базовый (два прохода),
-- только доп. джадж и объединение. Считаются по одним и тем же строкам,
-- поэтому разница между ними — это ровно вклад доп. джаджа.
$rows = (
    SELECT
        ok,
        AsList(
            <| variant: '1_base',       dis: p1 != p2 |>,
            <| variant: '2_extra_only', dis: e1 != e2 |>,
            <| variant: '3_merged',     dis: m1 != m2 |>
        ) AS variants,
        AsList(
            <| variant: '1_base',       side: 'A', g: gs_language, p: p1 |>,
            <| variant: '1_base',       side: 'B', g: gs_language, p: p2 |>,
            <| variant: '2_extra_only', side: 'A', g: gs_language, p: e1 |>,
            <| variant: '2_extra_only', side: 'B', g: gs_language, p: e2 |>,
            <| variant: '3_merged',     side: 'A', g: gs_language, p: m1 |>,
            <| variant: '3_merged',     side: 'B', g: gs_language, p: m2 |>
        ) AS pair
    FROM $joined
);

$flat = (
    SELECT ok, pair.variant AS variant, pair.side AS side, pair.g AS golden, pair.p AS pred
    FROM $rows FLATTEN BY pair
);

$confusion = (
    SELECT
        variant                                AS variant,
        SUM(IF(golden AND pred, 1, 0))         AS TP,
        SUM(IF(NOT golden AND pred, 1, 0))     AS FP,
        SUM(IF(golden AND NOT pred, 1, 0))     AS FN,
        SUM(IF(NOT golden AND NOT pred, 1, 0)) AS TN,
        COUNT(*)                               AS answers_total,
        SUM(IF(NOT ok, 1, 0))                  AS parse_failed
    FROM $flat
    GROUP BY variant
);

$variants_flat = (
    SELECT variants.variant AS variant, variants.dis AS dis
    FROM $rows FLATTEN BY variants
);

$consistency = (
    SELECT
        variant                     AS variant,
        COUNT(*)                    AS pairs_total,
        SUM(IF(dis, 1, 0))          AS pairs_sides_disagree
    FROM $variants_flat
    GROUP BY variant
);

-- Диагностика склейки и вклада доп. джаджа: одна строка на весь прогон,
-- цепляется к каждому варианту через CROSS JOIN.
$diag = (
    SELECT
        COUNT(*)                                              AS rows_scored,
        SUM(hit_by_id)                                        AS extra_hit_by_instruct_id,
        SUM(hit_by_join)                                      AS extra_hit_by_for_join,
        SUM(extra_missing)                                    AS extra_not_found,
        -- сколько флагов доп. джадж реально добавил поверх проходов
        SUM(IF(e1 AND NOT p1, 1, 0)) + SUM(IF(e2 AND NOT p2, 1, 0)) AS added_true,
        -- где проходы маркер поставили, а доп. джадж не увидел
        SUM(IF(p1 AND NOT e1, 1, 0)) + SUM(IF(p2 AND NOT e2, 1, 0)) AS only_passes,
        -- добор попал в золото / промазал
        SUM(IF(e1 AND NOT p1 AND gs_language, 1, 0))
            + SUM(IF(e2 AND NOT p2 AND gs_language, 1, 0))    AS added_true_hit_gold,
        SUM(IF(e1 AND NOT p1 AND NOT gs_language, 1, 0))
            + SUM(IF(e2 AND NOT p2 AND NOT gs_language, 1, 0)) AS added_true_miss_gold
    FROM $joined
);

-- Свод метрики и согласованности сторон отдельным шагом: цепочка
-- INNER JOIN ... USING (...) CROSS JOIN в одном FROM YQL не нравится.
$metrics = (
    SELECT
        c.variant                                                  AS variant,
        'language_errors_vs_gs'                                    AS marker,
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
    INNER JOIN $consistency AS k
    USING (variant)
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    m.*,
    -- одинаковые во всех трёх строках: это про склейку, а не про вариант
    d.rows_scored              AS rows_scored,
    d.extra_hit_by_instruct_id AS extra_hit_by_instruct_id,
    d.extra_hit_by_for_join    AS extra_hit_by_for_join,
    d.extra_not_found          AS extra_not_found,
    d.added_true               AS extra_added_true,
    d.only_passes              AS extra_only_passes,
    d.added_true_hit_gold      AS extra_added_true_hit_gold,
    d.added_true_miss_gold     AS extra_added_true_miss_gold
FROM $metrics AS m
CROSS JOIN $diag AS d
ORDER BY m.variant;

-- ===================== ВЫХОД 2: расхождения =====================
-- Только те ответы, где доп. джадж что-то поменял: видно, попал он в золото
-- или добавил ложное срабатывание, и рядом его обоснование.
$sides_raw = (
    SELECT
        instruct_id,
        gs_language,
        AsList(
            <| side: 'A', src: source_1, p: p1, e: e1, m: m1, w: e1_why, ans: answer_1 |>,
            <| side: 'B', src: source_2, p: p2, e: e2, m: m2, w: e2_why, ans: answer_2 |>
        ) AS sides_list
    FROM $joined
);

$sides = (
    SELECT
        instruct_id     AS instruct_id,
        gs_language     AS gs_language,
        sides_list.side AS side,
        sides_list.src  AS source,
        sides_list.p    AS pred_base,
        sides_list.e    AS pred_extra,
        sides_list.m    AS pred_merged,
        sides_list.w    AS extra_reasoning,
        sides_list.ans  AS answer
    FROM $sides_raw FLATTEN BY sides_list
);

INSERT INTO $output2 WITH TRUNCATE
SELECT
    instruct_id AS instruct_id,
    side        AS side,
    source      AS source,
    gs_language AS gold,
    pred_base   AS pred_base,
    pred_extra  AS pred_extra,
    pred_merged AS pred_merged,
    CASE
        WHEN pred_merged = gs_language AND NOT pred_base = gs_language THEN '1_добор_починил'
        WHEN NOT pred_merged = gs_language AND pred_base = gs_language THEN '2_добор_сломал'
        ELSE                                                               '3_без_изменений'
    END         AS effect,
    extra_reasoning AS extra_reasoning,
    -- MIN_OF с длиной: SUBSTRING не любит, когда просят больше, чем есть
    SUBSTRING(answer, 0, MIN_OF(CAST($answer_cut AS Uint32), LENGTH(answer))) AS answer_head
FROM $sides
WHERE pred_extra AND NOT pred_base
ORDER BY effect, instruct_id, side;
