-- Качество по речевым ошибкам против золота из target_markup.
-- Золото здесь не чекбоксы разметки, а вердикт голденсета:
--   {"task": "russian_language_problem", "verdict": 0|1|2} -> 0 = ошибок нет, 1+ = есть.
--
-- Вход:  $input1 — склейка прямого и обратного прохода (выход judge_merge_v4):
--                  instruct_id_real, markers_1_flags, markers_2_flags, parsed_ok;
--        $input2 — голденсет: instruct_id, target_markup.
-- Выход: одна строка с матрицей ошибок и метриками.
--
-- Сырой dst здесь уже не разбирается: в склеенной таблице маркеры лежат готовыми
-- флагами, объединёнными по обоим проходам. Поэтому ни Python, ни парсинга JSON.
--
-- Ключи: в $input1 instruct_id — это порядковый Int64, а настоящий ключ лежит
-- в instruct_id_real; в голденсете он называется instruct_id. Джойн идёт по ним,
-- иначе YQL падает с «Cannot compare key columns ... Int64 ... String».

PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;

$marker = 'language_errors';

$flag = ($flags, $name) -> {
    RETURN Yson::ConvertToBool(Yson::Lookup($flags, $name)) ?? false;
};

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
-- Строки без вердикта отбрасываем, иначе NULL стал бы «золотым false»
-- и разбавил бы отрицательный класс.
$gold = (
    SELECT
        g.instruct_id                                    AS instruct_id,
        Yson::ConvertToInt64(g.target_markup['verdict']) AS verdict
    FROM $input2 AS g
);

$gold_ = (
    SELECT
        instruct_id,
        verdict >= 1 AS gs_language
    FROM $gold
    WHERE verdict IS NOT NULL
);

$joined = (
    SELECT
        p.ok          AS ok,
        p.p1          AS p1,
        p.p2          AS p2,
        g.gs_language AS gs_language
    FROM $pred AS p
    INNER JOIN $gold_ AS g
    USING (instruct_id)
);

-- Ответы в паре одинаковые (голденсет размножен в answer_1/answer_2), поэтому
-- обе стороны сравниваются с одним и тем же золотом. Расхождение сторон при
-- идентичных ответах — это шум джаджа, его считаем отдельно.
$rows = (
    SELECT
        ok,
        p1 != p2 AS sides_disagree,
        AsList(
            <| side: 'A', g: gs_language, p: p1 |>,
            <| side: 'B', g: gs_language, p: p2 |>
        ) AS pair
    FROM $joined
);

$flat = (
    SELECT
        ok,
        pair.side AS side,
        pair.g    AS golden,
        pair.p    AS pred
    FROM $rows
    FLATTEN BY pair
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

-- Пар (строк) вдвое меньше, чем единиц оценки, поэтому расхождение сторон
-- считаем по $rows, а не по $flat.
$consistency = (
    SELECT
        COUNT(*)                      AS pairs_total,
        SUM(IF(sides_disagree, 1, 0)) AS pairs_sides_disagree
    FROM $rows
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    'language_errors_vs_gs' AS marker,

    c.TP AS TP, c.FP AS FP, c.FN AS FN, c.TN AS TN,

    (1.0 * c.TP) / MAX_OF(1.0, 1.0 * (c.TP + c.FP))            AS Precision,
    (1.0 * c.TP) / MAX_OF(1.0, 1.0 * (c.TP + c.FN))            AS Recall,
    (1.0 * (c.TP + c.TN)) / MAX_OF(1.0, 1.0 * c.answers_total) AS Accuracy,
    (2.0 * c.TP) / MAX_OF(1.0, 2.0 * c.TP + c.FP + c.FN)       AS F1_Score,

    -- Базовые ставки: без них P/R не читаются. golden_rate — доля ответов,
    -- где ошибка есть в золоте; pred_rate — доля, где её нашла модель.
    c.TP + c.FN                                                 AS golden_positives,
    c.TP + c.FP                                                 AS predicted_positives,
    (1.0 * (c.TP + c.FN)) / MAX_OF(1.0, 1.0 * c.answers_total)  AS golden_rate,
    (1.0 * (c.TP + c.FP)) / MAX_OF(1.0, 1.0 * c.answers_total)  AS pred_rate,

    c.answers_total AS answers_total,
    c.parse_failed  AS parse_failed,

    -- шум джаджа: одинаковым ответам выставлены разные вердикты
    k.pairs_total          AS pairs_total,
    k.pairs_sides_disagree AS pairs_sides_disagree,
    (1.0 * k.pairs_sides_disagree) / MAX_OF(1.0, 1.0 * k.pairs_total) AS sides_disagree_rate
FROM $confusion AS c
CROSS JOIN $consistency AS k;
