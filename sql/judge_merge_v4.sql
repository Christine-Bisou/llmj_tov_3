PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;

-- Склейка прямого и обратного прохода второго этапа (v4: аудит + SbS).
--
-- $input1 — прямой прогон (answer_1 шёл первым), $input2 — обратный.
--
-- ГДЕ ЛЕЖИТ ОТВЕТ ДЖАДЖА: dst — выход ПЕРВОГО этапа (маркеры),
-- dst_2 — выход ВТОРОГО (звёзды + аудит + sbs_comparison). Проводка та же,
-- что в judge_merge_pretty: прямой берём из i1.dst_2, обратный — из i2.dst.
-- Схемы это подтверждают: в прямой таблице есть dst_2/reasoning_dst_2 и нет dst,
-- в обратной — наоборот.
--
-- ГЛАВНОЕ ПРО РЕВЕРС: в обратном прогоне model_1 — это answer_2, а model_2 —
-- answer_1. Поэтому везде, где берём значения из обратного прохода для
-- answer_1, читаем ключ model_2_* — и наоборот. Вердикт зеркалим отдельно.
--
-- Что на выходе:
--   pointwise_1 / pointwise_2 — звёзды по трём аспектам + общая, с разбивкой
--                               по проходам и усреднением;
--   markers_1 / markers_2     — словарь 13 маркеров после аудита, с пометкой,
--                               в каком проходе маркер сработал;
--   sbs                       — вердикт с обоих проходов, сразу в сорсах.

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

$marker_names = AsList(
    'empathy', 'subjectivity', 'tone_match', 'humor_metaphors', 'critical_tone',
    'bad_intro', 'bad_proactivity', 'over_emotional', 'stuffy_bureaucratic',
    'boundaries_violation', 'template_phrases', 'language_errors', 'inconsistency'
);

-- ========================= ЗВЁЗДЫ =========================
-- ConvertToDouble вместо LookupInt64: переживёт и 4, и 4.0, и "4".
$score = ($node, $model, $asp) -> {
    RETURN Yson::ConvertToDouble(
        Yson::Lookup(Yson::Lookup(Yson::Lookup($node, $model), $asp), 'score')
    ) ?? 0.0;
};

$reason = ($node, $model, $asp) -> {
    RETURN Yson::LookupString(
        Yson::Lookup(Yson::Lookup($node, $model), $asp), 'reasoning'
    ) ?? '';
};

$avg = ($dir, $rev, $md, $mr, $asp) -> {
    RETURN ($score($dir, $md, $asp) + $score($rev, $mr, $asp)) / 2.0;
};

-- Итоговая звезда: среднее двух проходов, округлённое ВНИЗ (4 и 5 -> 4.5 -> 4).
$star = ($dir, $rev, $md, $mr, $asp) -> {
    RETURN CAST(Math::Floor($avg($dir, $rev, $md, $mr, $asp)) AS Int64);
};

$aspect_block = ($dir, $rev, $md, $mr, $asp) -> {
    RETURN <|
        score:     $star($dir, $rev, $md, $mr, $asp),
        avg:       $avg($dir, $rev, $md, $mr, $asp),
        direct:    $score($dir, $md, $asp),
        reversed:  $score($rev, $mr, $asp),
        reasoning: $reason($dir, $md, $asp)
    |>;
};

-- $md — ключ этого ответа в прямом проходе, $mr — в обратном (там всё зеркально).
$pointwise = ($dir, $rev, $md, $mr) -> {
    RETURN Just(Yson::From(<|
        clarity:    $aspect_block($dir, $rev, $md, $mr, 'clarity'),
        liveliness: $aspect_block($dir, $rev, $md, $mr, 'liveliness'),
        connect:    $aspect_block($dir, $rev, $md, $mr, 'connect'),
        overall:    $aspect_block($dir, $rev, $md, $mr, 'overall')
    |>));
};

-- Четыре числа без обвязки — формат разметки.
$clc = ($dir, $rev, $md, $mr) -> {
    RETURN Just(Yson::From(<|
        clarity:    $star($dir, $rev, $md, $mr, 'clarity'),
        liveliness: $star($dir, $rev, $md, $mr, 'liveliness'),
        connect:    $star($dir, $rev, $md, $mr, 'connect'),
        overall:    $star($dir, $rev, $md, $mr, 'overall')
    |>));
};

-- ========================= МАРКЕРЫ =========================
-- v4 отдаёт разметку после аудита: model_N_markers_review.markers.
$mk = ($node, $review_key) -> {
    RETURN Yson::Lookup(Yson::Lookup($node, $review_key), 'markers');
};

$is_on = ($mk_node, $name) -> {
    RETURN Yson::ConvertToBool(
        Yson::Lookup(Yson::Lookup($mk_node, $name), 'is_present')
    ) ?? false;
};

$why = ($mk_node, $name) -> {
    RETURN Yson::LookupString(Yson::Lookup($mk_node, $name), 'explanation') ?? '';
};

$audit = ($mk_node, $name) -> {
    RETURN Yson::LookupString(Yson::Lookup($mk_node, $name), 'audit') ?? '';
};

-- Маркер считаем выставленным, если его увидел ХОТЯ БЫ один проход:
-- пропуск маркера — настоящая ошибка, лишнее срабатывание видно по in_direct /
-- in_reversed и по agreed, так что объединение ничего не прячет.
$markers = ($d_mk, $r_mk) -> {
    RETURN Just(Yson::From(ToDict(ListMap($marker_names, ($n) -> {
        RETURN AsTuple($n, <|
            is_present:  $is_on($d_mk, $n) OR $is_on($r_mk, $n),
            in_direct:   $is_on($d_mk, $n),
            in_reversed: $is_on($r_mk, $n),
            agreed:      $is_on($d_mk, $n) == $is_on($r_mk, $n),
            audit:       IF($audit($d_mk, $n) != '', $audit($d_mk, $n), $audit($r_mk, $n)),
            explanation: IF($is_on($d_mk, $n), $why($d_mk, $n), $why($r_mk, $n))
        |>);
    }))));
};

-- Только флаги, без пояснений — для метрик и джойнов с золотом.
$marker_flags = ($d_mk, $r_mk) -> {
    RETURN Just(Yson::From(ToDict(ListMap($marker_names, ($n) -> {
        RETURN AsTuple($n, $is_on($d_mk, $n) OR $is_on($r_mk, $n));
    }))));
};

$marker_list = ($d_mk, $r_mk) -> {
    RETURN ListFilter($marker_names, ($n) -> {
        RETURN $is_on($d_mk, $n) OR $is_on($r_mk, $n);
    });
};

-- Доля маркеров, по которым проходы сошлись: низкая — повод посмотреть строку руками.
$marker_agreement = ($d_mk, $r_mk) -> {
    RETURN CAST(ListLength(ListFilter($marker_names, ($n) -> {
        RETURN $is_on($d_mk, $n) == $is_on($r_mk, $n);
    })) AS Double) / CAST(ListLength($marker_names) AS Double);
};

-- ========================= ВЕРДИКТ =========================
$verdict = ($node) -> {
    RETURN Yson::LookupString(Yson::Lookup($node, 'sbs_comparison'), 'verdict') ?? 'tie';
};

$sbs_why = ($node) -> {
    RETURN Yson::LookupString(Yson::Lookup($node, 'sbs_comparison'), 'reasoning') ?? '';
};

-- В обратном проходе model_1 — это answer_2, поэтому вердикт зеркалим.
$flip = ($v) -> {
    RETURN CASE WHEN $v = 'model_1' THEN 'model_2'
                WHEN $v = 'model_2' THEN 'model_1'
                ELSE 'tie' END;
};

-- Победитель сразу сорсом, а не «model_1»: имя модели читается без сверки с таблицей.
-- В этих таблицах сорсы лежат в колонках source_A / source_B (answer_source_1/2
-- появляются только после judge_merge_pretty — здесь их нет).
-- 'tie' и 'conflict' пробрасываем как есть: подменять их на 'tie' нельзя,
-- иначе несогласие проходов растворится в честных ничьих.
$as_source = ($w, $s1, $s2) -> {
    $n1 = COALESCE(CAST($s1 AS String), '');
    $n2 = COALESCE(CAST($s2 AS String), '');
    RETURN CASE $w
        WHEN 'model_1' THEN IF($n1 != '', $n1, 'model_1')
        WHEN 'model_2' THEN IF($n2 != '', $n2, 'model_2')
        ELSE COALESCE($w, 'tie')
    END;
};

-- ========================= РАЗБОР =========================
-- dst_2 — второй этап прямого прогона, dst — второй этап обратного.
$parsed = (
    SELECT
        i1.*,
        $process_json(CAST(i1.dst_2 AS String)) AS dir_yson,
        $process_json(CAST(i2.dst   AS String)) AS rev_yson
    FROM $input1 AS i1
    INNER JOIN $input2 AS i2
    USING (instruct_id)
);

$calc = (
    SELECT
        $verdict(dir_yson)          AS w_direct,
        $flip($verdict(rev_yson))   AS w_reversed_norm,

        $mk(dir_yson, 'model_1_markers_review') AS mk1_dir,
        $mk(dir_yson, 'model_2_markers_review') AS mk2_dir,
        -- в обратном проходе разметка answer_1 лежит под model_2 — и наоборот
        $mk(rev_yson, 'model_2_markers_review') AS mk1_rev,
        $mk(rev_yson, 'model_1_markers_review') AS mk2_rev,

        -- tov_winner мог остаться от прошлых склеек: снимаем, иначе алиас ниже
        -- упрётся в «Duplicated member». Звёздочка с WITHOUT — строго последняя
        -- в списке: после неё парсер ждёт только имена колонок.
        p.* WITHOUT IF EXISTS p.tov_winner
    FROM $parsed AS p
);

$final = (
    SELECT
        c.*,
        CASE
            WHEN w_direct = w_reversed_norm            THEN w_direct
            WHEN w_direct IN ('tie', 'draw')           THEN w_reversed_norm
            WHEN w_reversed_norm IN ('tie', 'draw')    THEN w_direct
            -- проходы назвали разных победителей: это не ничья по существу,
            -- а несогласие джаджа — помечаем отдельно, чтобы не мешать с tie
            ELSE 'conflict'
        END AS tov_winner
    FROM $calc AS c
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    -- ---------- звёзды ----------
    $pointwise(f.dir_yson, f.rev_yson, 'model_1_evaluation', 'model_2_evaluation') AS pointwise_1,
    $pointwise(f.dir_yson, f.rev_yson, 'model_2_evaluation', 'model_1_evaluation') AS pointwise_2,
    $clc(f.dir_yson, f.rev_yson, 'model_1_evaluation', 'model_2_evaluation')       AS clc_metrics_1,
    $clc(f.dir_yson, f.rev_yson, 'model_2_evaluation', 'model_1_evaluation')       AS clc_metrics_2,

    -- плоские звёзды: в таблицах уже есть clarity_1 / liveliness_1 / connect_1 /
    -- overall_1 с прошлой склейки, и без пересчёта они разошлись бы с pointwise.
    -- Старые снимаем в WITHOUT ниже.
    $star(f.dir_yson, f.rev_yson, 'model_1_evaluation', 'model_2_evaluation', 'clarity')    AS clarity_1,
    $star(f.dir_yson, f.rev_yson, 'model_2_evaluation', 'model_1_evaluation', 'clarity')    AS clarity_2,
    $star(f.dir_yson, f.rev_yson, 'model_1_evaluation', 'model_2_evaluation', 'liveliness') AS liveliness_1,
    $star(f.dir_yson, f.rev_yson, 'model_2_evaluation', 'model_1_evaluation', 'liveliness') AS liveliness_2,
    $star(f.dir_yson, f.rev_yson, 'model_1_evaluation', 'model_2_evaluation', 'connect')    AS connect_1,
    $star(f.dir_yson, f.rev_yson, 'model_2_evaluation', 'model_1_evaluation', 'connect')    AS connect_2,
    $star(f.dir_yson, f.rev_yson, 'model_1_evaluation', 'model_2_evaluation', 'overall')    AS overall_1,
    $star(f.dir_yson, f.rev_yson, 'model_2_evaluation', 'model_1_evaluation', 'overall')    AS overall_2,

    -- ---------- маркеры ----------
    $markers(f.mk1_dir, f.mk1_rev)           AS markers_1,
    $markers(f.mk2_dir, f.mk2_rev)           AS markers_2,
    $marker_flags(f.mk1_dir, f.mk1_rev)      AS markers_1_flags,
    $marker_flags(f.mk2_dir, f.mk2_rev)      AS markers_2_flags,
    $marker_list(f.mk1_dir, f.mk1_rev)       AS markers_1_list,
    $marker_list(f.mk2_dir, f.mk2_rev)       AS markers_2_list,
    $marker_agreement(f.mk1_dir, f.mk1_rev)  AS markers_1_agreement,
    $marker_agreement(f.mk2_dir, f.mk2_rev)  AS markers_2_agreement,

    -- ---------- вердикт ----------
    -- source_A / source_B — это колонки входных таблиц (см. $as_source выше)
    Just(Yson::From(<|
        winner:            $as_source(f.tov_winner, f.source_A, f.source_B),
        winner_model:      f.tov_winner,
        direct:            $as_source(f.w_direct, f.source_A, f.source_B),
        reversed:          $as_source(f.w_reversed_norm, f.source_A, f.source_B),
        agreement:         IF(f.w_direct = f.w_reversed_norm, 1.0, 0.0),
        strength:          IF(f.w_direct = f.w_reversed_norm, 'strong', 'weak'),
        reasoning_direct:  $sbs_why(f.dir_yson),
        reasoning_reversed: $sbs_why(f.rev_yson)
    |>))                                     AS sbs,

    -- плоско, чтобы фильтровать и группировать без Yson::Lookup
    $as_source(f.tov_winner, f.source_A, f.source_B) AS tov_winner_source,

    Just(Yson::From(<|
        model_winner_direct:              f.w_direct,
        model_winner_reversed_normalized: f.w_reversed_norm,
        reasoning_direct:                 $sbs_why(f.dir_yson),
        reasoning_reversed:               $sbs_why(f.rev_yson),
        direct_m1_overall:                $score(f.dir_yson, 'model_1_evaluation', 'overall'),
        direct_m2_overall:                $score(f.dir_yson, 'model_2_evaluation', 'overall'),
        reversed_m1_overall:              $score(f.rev_yson, 'model_2_evaluation', 'overall'),
        reversed_m2_overall:              $score(f.rev_yson, 'model_1_evaluation', 'overall'),
        process_url:                      'https://nirvana.yandex-team.ru/process/9113ab38-0999-4125-b182-523e63252411',
        graph_owner:                      'kristisha'
    |>))                                     AS meta_info,

    -- WITHOUT обязан быть последним элементом списка.
    -- Первый блок — служебное этого запроса, второй — сырые ответы джаджа
    -- (dst — первый этап, dst_2 — второй), третий — колонки, которые мы
    -- только что пересчитали: они уже есть во входной таблице с прошлых
    -- этапов, и без снятия YQL падает с «Duplicated member».
    f.* WITHOUT IF EXISTS
        f.dir_yson, f.rev_yson, f.pass_order,
        f.mk1_dir, f.mk2_dir, f.mk1_rev, f.mk2_rev,
        f.w_direct, f.w_reversed_norm,

        f.dst, f.dst_2, f.reasoning_dst, f.reasoning_dst_2,
        f.infer_dialog, f.tov_prompt, f._other,

        f.pointwise_1, f.pointwise_2,
        f.clc_metrics_1, f.clc_metrics_2,
        f.clarity_1, f.clarity_2, f.liveliness_1, f.liveliness_2,
        f.connect_1, f.connect_2, f.overall_1, f.overall_2,
        f.markers_1, f.markers_2,
        f.markers_1_flags, f.markers_2_flags,
        f.markers_1_list, f.markers_2_list,
        f.markers_1_agreement, f.markers_2_agreement,
        f.sbs, f.tov_winner_source, f.meta_info
FROM $final AS f;
