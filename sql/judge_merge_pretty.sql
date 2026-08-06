PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

-- input1 — прямой прогон, input2 — обратный.
-- В обеих таблицах: dst  = выход ПЕРВОГО этапа (маркеры + звёзды по каждому ответу),
--                   dst_2 = выход ВТОРОГО этапа (аудит звёзд + sbs_comparison).
-- Ниже сохранена твоя проводка: прямой берём из i1.dst_2, обратный из i2.dst.
-- Если обратный прогон тоже кладёт второй этап в dst_2 — поменяй на i2.dst_2.
--
-- Что где лежит на выходе:
--   pointwise_1 / pointwise_2       — первый этап. Он проходит по каждому ответу
--                                     ОДИН раз, поэтому там просто score и
--                                     reasoning на аспект, без проходов и средних.
--   checked_pointwise_A / _B        — второй этап. Он судит пару дважды, поэтому
--                                     там direct и reversed, в каждом — оценки
--                                     аспектов и аудит маркеров.
--   clc_metrics_1 / clc_metrics_2   — агрегат второго этапа: среднее двух проходов.
--   sbs                             — вердикт: победитель источником ответа и
--                                     обоснование, обратный проход нормализован.

$yson_null = Just(Yson::From({}));

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

-- ========================= ОЦЕНКИ ПО АСПЕКТАМ =========================
-- Блок оценок одного ответа. У первого этапа он может лежать под ключом
-- 'evaluation' (промпт получает один ответ) или под 'model_N_evaluation'
-- (оба ответа за один вызов) — поддерживаем оба варианта.
$eval_node = ($node, $model) -> {
    RETURN Yson::Lookup($node, $model) ?? Yson::Lookup($node, 'evaluation');
};

-- ConvertToDouble вместо LookupInt64: переживёт и 4, и 4.0, и "4".
$asp_score = ($eval, $asp) -> {
    RETURN Yson::ConvertToDouble(Yson::Lookup(Yson::Lookup($eval, $asp), 'score')) ?? 0.0;
};

$asp_why = ($eval, $asp) -> {
    RETURN Yson::LookupString(Yson::Lookup($eval, $asp), 'reasoning') ?? '';
};

$aspect = ($node, $model, $asp) -> {
    RETURN $asp_score($eval_node($node, $model), $asp);
};

-- Аспект как его выдал джадж: оценка и обоснование, без агрегатов.
$asp_block = ($eval, $asp) -> {
    RETURN <|
        score:     CAST(Math::Floor($asp_score($eval, $asp) + 0.5) AS Int64),
        reasoning: $asp_why($eval, $asp)
    |>;
};

-- Четыре аспекта одного ответа одним куском — ровно та структура, которую
-- отдаёт промпт: {clarity, liveliness, connect, overall} × {score, reasoning}.
$eval_block = ($eval) -> {
    RETURN <|
        clarity:    $asp_block($eval, 'clarity'),
        liveliness: $asp_block($eval, 'liveliness'),
        connect:    $asp_block($eval, 'connect'),
        overall:    $asp_block($eval, 'overall')
    |>;
};

-- ПЕРВЫЙ ЭТАП. Проходит по каждому ответу один раз, поэтому здесь нет ни
-- прямого с обратным, ни среднего: одна оценка и одно обоснование на аспект.
$pointwise = ($node, $model) -> {
    RETURN Just(Yson::From($eval_block($eval_node($node, $model))));
};

-- ВТОРОЙ ЭТАП. Пара судится дважды, поэтому у проверенных оценок два прохода.
-- В обратном проходе ответы переставлены: ответ A лежит в 'model_2_evaluation'.
-- Агрегат по двум проходам не дублируем — он лежит в clc_metrics.
$checked_side = ($node, $eval_key, $review_key) -> {
    RETURN <|
        evaluation:     $eval_block($eval_node($node, $eval_key)),
        markers_review: Yson::Lookup($node, $review_key) ?? Yson::From(<||>)
    |>;
};

$checked_pointwise = ($dir, $dir_eval, $dir_review, $rev, $rev_eval, $rev_review) -> {
    RETURN Just(Yson::From(<|
        direct:   $checked_side($dir, $dir_eval, $dir_review),
        reversed: $checked_side($rev, $rev_eval, $rev_review)
    |>));
};

-- Итоговая оценка аспекта: среднее двух проходов, округлённое ВНИЗ.
-- 4 и 5 -> 4.5 -> 4. Именно это число мы и ставим.
$final = ($dir, $rev, $md, $mr, $asp) -> {
    RETURN CAST(Math::Floor(($aspect($dir, $md, $asp) + $aspect($rev, $mr, $asp)) / 2.0) AS Int64);
};

-- clc_metrics для одного ответа: четыре числа, ничего лишнего.
-- $md — ключ этого ответа в прямом прогоне, $mr — в обратном (там ответы переставлены).
$clc = ($dir, $rev, $md, $mr) -> {
    RETURN Just(Yson::From(<|
        clarity:    $final($dir, $rev, $md, $mr, 'clarity'),
        liveliness: $final($dir, $rev, $md, $mr, 'liveliness'),
        connect:    $final($dir, $rev, $md, $mr, 'connect'),
        overall:    $final($dir, $rev, $md, $mr, 'overall')
    |>));
};

-- ========================= МАРКЕРЫ =========================
-- Новая структура: {имя_маркера: {is_present: bool, explanation: string}}
$marker_names = AsList(
    'empathy', 'subjectivity', 'tone_match', 'humor_metaphors', 'critical_tone',
    'bad_intro', 'bad_proactivity', 'over_emotional', 'stuffy_bureaucratic',
    'boundaries_violation', 'template_phrases', 'language_errors', 'inconsistency'
);

$is_on = ($m, $name) -> {
    RETURN Yson::ConvertToBool(Yson::Lookup(Yson::Lookup($m, $name), 'is_present')) ?? false;
};

-- список имён сработавших маркеров — удобно глазами и для группировок
$present = ($m) -> {
    RETURN ListFilter($marker_names, ($n) -> { RETURN $is_on($m, $n); });
};

-- нормализованный словарь: только флаги, без пояснений
$flags = ($m) -> {
    RETURN Just(Yson::From(ToDict(ListMap($marker_names, ($n) -> {
        RETURN AsTuple($n, $is_on($m, $n));
    }))));
};

-- чекбоксы в формате разметки.
-- tov_minus_addressing теперь берётся из inconsistency (раньше был захардкожен false).
-- tov_plus_clarity убран: маркера ясности больше не существует.
$markers_to_checkboxes = ($m) -> {
    RETURN Just(Yson::From(<|
        point_bad_intro:              $is_on($m, 'bad_intro'),
        point_bad_proactivity:        $is_on($m, 'bad_proactivity'),
        tov_minus_addressing:         $is_on($m, 'inconsistency'),
        tov_minus_boundary_violation: $is_on($m, 'boundaries_violation'),
        tov_minus_cliches:            $is_on($m, 'template_phrases'),
        tov_minus_dry:                $is_on($m, 'stuffy_bureaucratic'),
        tov_minus_language_errors:    $is_on($m, 'language_errors'),
        tov_minus_overemotional:      $is_on($m, 'over_emotional'),
        tov_plus_empathy:             $is_on($m, 'empathy'),
        tov_plus_humor:               $is_on($m, 'humor_metaphors'),
        tov_plus_subject:             $is_on($m, 'subjectivity'),
        tov_plus_tone_match:          $is_on($m, 'tone_match'),
        tov_tone_unacceptable:        $is_on($m, 'critical_tone')
    |>));
};

$verdict = ($node) -> {
    RETURN Yson::LookupString(Yson::Lookup($node, 'sbs_comparison'), 'verdict') ?? 'draw';
};

$sbs_why = ($node) -> {
    RETURN Yson::LookupString(Yson::Lookup($node, 'sbs_comparison'), 'reasoning') ?? '';
};

$flip = ($v) -> {
    RETURN CASE WHEN $v = 'model_1' THEN 'model_2'
                WHEN $v = 'model_2' THEN 'model_1'
                ELSE 'draw' END;
};

$winner_source = ($w, $s1, $s2) -> {
    RETURN CASE $w
        WHEN 'model_1' THEN COALESCE(CAST($s1 AS String), '')
        WHEN 'model_2' THEN COALESCE(CAST($s2 AS String), '')
        ELSE 'draw'
    END;
};

-- Сторона победителя буквой ответа, а не именем модели из промпта.
$winner_side = ($w) -> {
    RETURN CASE $w
        WHEN 'model_1' THEN 'A'
        WHEN 'model_2' THEN 'B'
        ELSE 'draw'
    END;
};

-- ========================= РАЗБОР =========================
$parsed = (
    SELECT
        d.*,

        $verdict(dst_yson_direct)            AS model_winner_direct,
        $verdict(dst_yson_reversed)          AS model_winner_reversed,
        $flip($verdict(dst_yson_reversed))   AS model_winner_reversed_normalized,

        -- красивые метрики по каждому ответу
        $clc(dst_yson_direct, dst_yson_reversed, 'model_1_evaluation', 'model_2_evaluation') AS clc_metrics_1,
        $clc(dst_yson_direct, dst_yson_reversed, 'model_2_evaluation', 'model_1_evaluation') AS clc_metrics_2,

        -- звёзды первого этапа: по одному значению на аспект, без проходов
        $pointwise(dst_yson_pointwise, 'model_1_evaluation') AS pointwise_1,
        $pointwise(dst_yson_pointwise, 'model_2_evaluation') AS pointwise_2,

        -- что со звёздами и маркерами сделал второй этап, по обоим проходам.
        -- A — это answer_1, B — answer_2; в обратном проходе они переставлены.
        $checked_pointwise(
            dst_yson_direct,   'model_1_evaluation', 'model_1_markers_review',
            dst_yson_reversed, 'model_2_evaluation', 'model_2_markers_review'
        ) AS checked_pointwise_A,
        $checked_pointwise(
            dst_yson_direct,   'model_2_evaluation', 'model_2_markers_review',
            dst_yson_reversed, 'model_1_evaluation', 'model_1_markers_review'
        ) AS checked_pointwise_B,

        -- маркеры: подробно, флагами и списком имён
        Just(Yson::From(mk1))                AS markers_1,
        Just(Yson::From(mk2))                AS markers_2,
        $flags(mk1)                          AS markers_1_flags,
        $flags(mk2)                          AS markers_2_flags,
        $present(mk1)                        AS markers_1_list,
        $present(mk2)                        AS markers_2_list,

        Just(Yson::From(<|
            model_winner_direct:              $verdict(dst_yson_direct),
            model_winner_reversed:            $verdict(dst_yson_reversed),
            model_winner_reversed_normalized: $flip($verdict(dst_yson_reversed)),
            reasoning_direct:                 $sbs_why(dst_yson_direct),
            reasoning_reversed:               $sbs_why(dst_yson_reversed),
            direct_m1_overall:                $aspect(dst_yson_direct,   'model_1_evaluation', 'overall'),
            direct_m2_overall:                $aspect(dst_yson_direct,   'model_2_evaluation', 'overall'),
            reversed_m1_overall:              $aspect(dst_yson_reversed, 'model_2_evaluation', 'overall'),
            reversed_m2_overall:              $aspect(dst_yson_reversed, 'model_1_evaluation', 'overall'),
            process_url:                      'https://nirvana.yandex-team.ru/process/9113ab38-0999-4125-b182-523e63252411',
            graph_owner:                      'kristisha'
        |>))                                 AS meta_info

    FROM (
        SELECT
            i1.*,
            -- первый этап проходит по паре один раз, порядок ответов на него не
            -- влияет — берём его только из прямой таблицы
            $process_json(CAST(i1.dst   AS String)) AS dst_yson_pointwise,
            $process_json(CAST(i1.dst_2 AS String)) AS dst_yson_direct,
            $process_json(CAST(i2.dst   AS String)) AS dst_yson_reversed,
            -- маркеры первого этапа берём из прямой таблицы: там ext_markers_1
            -- относится к answer_1, ext_markers_2 — к answer_2, без перестановок
            i1.ext_markers_1                        AS mk1,
            i1.ext_markers_2                        AS mk2
        FROM {{input1}} AS i1
        INNER JOIN {{input2}} AS i2
        USING (instruct_id)
    ) AS d
);

$winner_raw = (
    SELECT
        p.*,
        CASE
            WHEN model_winner_direct = model_winner_reversed_normalized
                THEN model_winner_direct
            WHEN model_winner_direct IN ('draw', 'tie')
                THEN model_winner_reversed_normalized
            WHEN model_winner_reversed_normalized IN ('draw', 'tie')
                THEN model_winner_direct
            ELSE 'draw'
        END AS tov_winner
    FROM $parsed AS p
);

-- Вердикт отдельной колонкой и сразу в читаемом виде: победитель назван
-- источником ответа, а не 'model_1', причём обратный проход уже нормализован.
$winner_calc = (
    SELECT
        w.*,
        Just(Yson::From(<|
            winner:      $winner_source(w.tov_winner, w.answer_source_1, w.answer_source_2),
            winner_side: $winner_side(w.tov_winner),
            reasoning:   IF(
                w.model_winner_reversed_normalized = w.tov_winner
                    AND w.model_winner_direct != w.tov_winner,
                $sbs_why(w.dst_yson_reversed),
                $sbs_why(w.dst_yson_direct)
            ),
            agreement:   IF(w.model_winner_direct = w.model_winner_reversed_normalized, 'strong', 'weak'),
            direct: <|
                winner:      $winner_source(w.model_winner_direct, w.answer_source_1, w.answer_source_2),
                winner_side: $winner_side(w.model_winner_direct),
                reasoning:   $sbs_why(w.dst_yson_direct)
            |>,
            reversed: <|
                winner:      $winner_source(w.model_winner_reversed_normalized, w.answer_source_1, w.answer_source_2),
                winner_side: $winner_side(w.model_winner_reversed_normalized),
                reasoning:   $sbs_why(w.dst_yson_reversed)
            |>
        |>)) AS sbs
    FROM $winner_raw AS w
);

-- ========================= ВЫХОД 1: рабочая таблица =========================
INSERT INTO {{output1}} WITH TRUNCATE
SELECT
    -- дополнительные колонки идут ДО wc.*: WITHOUT обязан быть последним в списке
    $winner_source(wc.tov_winner, wc.answer_source_1, wc.answer_source_2) AS tov_winner_source,
    wc.*,
    WITHOUT IF EXISTS
        wc.dst, wc.dst_2,
        wc.dst_yson_pointwise, wc.dst_yson_direct, wc.dst_yson_reversed,
        wc.mk1, wc.mk2,
        wc.infer_dialog, wc.tov_prompt,
        wc.reasoning_dst, wc.reasoning_dst_2,
        wc.model_winner_direct, wc.model_winner_reversed, wc.model_winner_reversed_normalized
FROM $winner_calc AS wc;

-- ========================= ВЫХОД 2: формат разметки =========================
INSERT INTO {{output2}} WITH TRUNCATE
SELECT
    wc.instruct_id AS instruct_id,

    Just(Yson::From(<|
        task_id:    COALESCE(CAST(wc.instruct_id AS String), ''),
        pool_id:    $yson_null,
        project_id: $yson_null,
        answer_A:   COALESCE(CAST(wc.answer_1 AS String), ''),
        answer_B:   COALESCE(CAST(wc.answer_2 AS String), ''),
        source_A:   COALESCE(CAST(wc.answer_source_1 AS String), ''),
        source_B:   COALESCE(CAST(wc.answer_source_2 AS String), ''),
        checkboxes: Just(Yson::From(<||>)),
        markers:    Just(Yson::From(AsList())),

        raw_outputs: AsList(
            <|
                worker_id:       'direct',
                assignment_id:   $yson_null,
                annotations:     Just(Yson::From(AsList())),
                checkboxes_A:    $markers_to_checkboxes(wc.mk1),
                checkboxes_B:    $markers_to_checkboxes(wc.mk2),
                clc_metrics_A:   wc.clc_metrics_1,
                clc_metrics_B:   wc.clc_metrics_2,
                comment_A:       $yson_null,
                comment_B:       $yson_null,
                general_comment: COALESCE(Yson::LookupString(wc.meta_info, 'reasoning_direct'), ''),
                comment_judge:   $yson_null,
                diff_pa:         $yson_null,
                diff_pa_winner:  $winner_source(wc.model_winner_direct, wc.answer_source_1, wc.answer_source_2),
                direct_speech_A: $yson_null,
                direct_speech_B: $yson_null,
                markup_dt:       $yson_null,
                skip:            $yson_null,
                winner:          $winner_source(wc.model_winner_direct, wc.answer_source_1, wc.answer_source_2)
            |>,
            <|
                worker_id:       'reverse',
                assignment_id:   $yson_null,
                annotations:     Just(Yson::From(AsList())),
                checkboxes_A:    $markers_to_checkboxes(wc.mk1),
                checkboxes_B:    $markers_to_checkboxes(wc.mk2),
                clc_metrics_A:   wc.clc_metrics_1,
                clc_metrics_B:   wc.clc_metrics_2,
                comment_A:       $yson_null,
                comment_B:       $yson_null,
                general_comment: COALESCE(Yson::LookupString(wc.meta_info, 'reasoning_reversed'), ''),
                comment_judge:   $yson_null,
                diff_pa:         $yson_null,
                diff_pa_winner:  $winner_source(wc.model_winner_reversed_normalized, wc.answer_source_1, wc.answer_source_2),
                direct_speech_A: $yson_null,
                direct_speech_B: $yson_null,
                markup_dt:       $yson_null,
                skip:            $yson_null,
                winner:          $winner_source(wc.model_winner_reversed_normalized, wc.answer_source_1, wc.answer_source_2)
            |>
        )
    |>)) AS raw_tov_markup,

    Just(Yson::From(<|
        task_id:    COALESCE(CAST(wc.instruct_id AS String), ''),
        pool_id:    $yson_null,
        project_id: $yson_null,
        worker_ids: AsList('direct', 'reverse'),

        answer_A:   COALESCE(CAST(wc.answer_1 AS String), ''),
        answer_B:   COALESCE(CAST(wc.answer_2 AS String), ''),
        source_A:   COALESCE(CAST(wc.answer_source_1 AS String), ''),
        source_B:   COALESCE(CAST(wc.answer_source_2 AS String), ''),

        checkboxes_A: $markers_to_checkboxes(wc.mk1),
        checkboxes_B: $markers_to_checkboxes(wc.mk2),

        clc_metrics_A: wc.clc_metrics_1,
        clc_metrics_B: wc.clc_metrics_2,

        markers_A: wc.markers_1_list,
        markers_B: wc.markers_2_list,

        annotations:      AsList(AsList(), AsList()),
        comments_A:       AsList('', ''),
        comments_B:       AsList('', ''),
        general_comments: AsList(
            COALESCE(Yson::LookupString(wc.meta_info, 'reasoning_direct'),   ''),
            COALESCE(Yson::LookupString(wc.meta_info, 'reasoning_reversed'), '')
        ),

        task_summarization: $yson_null,

        diff_pa:                  false,
        diff_pa_winner:           $winner_source(wc.tov_winner, wc.answer_source_1, wc.answer_source_2),
        diff_pa_winner_agreement: IF(wc.model_winner_direct = wc.model_winner_reversed_normalized, 1.0, 0.0),
        diff_pa_winner_strength:  IF(wc.model_winner_direct = wc.model_winner_reversed_normalized, 'strong', 'weak'),

        direct_speech_A: false,
        direct_speech_B: false,

        winner:            $winner_source(wc.tov_winner, wc.answer_source_1, wc.answer_source_2),
        winner_agreement:  IF(wc.model_winner_direct = wc.model_winner_reversed_normalized, 1.0, 0.0),
        winner_strength:   IF(wc.model_winner_direct = wc.model_winner_reversed_normalized, 'strong', 'weak'),

        skip: false
    |>)) AS agg_tov_markup

FROM $winner_calc AS wc;
