PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

-- input1 — прямой прогон, input2 — обратный.
-- В обеих таблицах: dst  = выход ПЕРВОГО этапа (маркеры),
--                   dst_2 = выход ВТОРОГО этапа (звёзды + sbs_comparison).
-- Ниже сохранена твоя проводка: прямой берём из i1.dst_2, обратный из i2.dst.
-- Если обратный прогон тоже кладёт второй этап в dst_2 — поменяй на i2.dst_2.
--
-- Соответствие ответов и ключей во втором этапе:
--   прямой прогон:  model_1_evaluation -> answer_1, model_2_evaluation -> answer_2
--   обратный:       model_1_evaluation -> answer_2, model_2_evaluation -> answer_1
-- Маркеры первого этапа перестановке не подвергались: ext_markers_1 — всегда answer_1.
--
-- Выход 1 — рабочая таблица, к ней уже приклеены agg_tov_markup и raw_tov_markup.
-- Выход 2 — те же две колонки отдельной таблицей под приёмник разметки.

$yson_null = Just(Yson::From({}));
$empty_list = ListCreate(String);

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
$aspects = AsList('clarity', 'liveliness', 'connect', 'overall');

-- Оценка аспекта одним проходом. Осознанно БЕЗ `?? 0.0`:
-- отсутствующая оценка должна остаться null, иначе она утянет среднее вниз
-- и в таблицу уедет честная на вид, но выдуманная двойка.
-- ConvertToDouble вместо LookupInt64: переживёт и 4, и 4.0, и "4".
$score = ($node, $model, $asp) -> {
    RETURN Yson::ConvertToDouble(
        Yson::Lookup(Yson::Lookup(Yson::Lookup($node, $model), $asp), 'score')
    );
};

$score_why = ($node, $model, $asp) -> {
    RETURN Yson::LookupString(
        Yson::Lookup(Yson::Lookup($node, $model), $asp), 'reasoning'
    ) ?? '';
};

-- Оценка одного прохода как целое.
$score_int = ($node, $model, $asp) -> {
    RETURN CAST(Math::Floor($score($node, $model, $asp)) AS Int64);
};

-- Среднее двух проходов. Если проход оценку не поставил — берём второй как есть,
-- если не поставил ни один — остаётся null.
$avg2 = ($a, $b) -> {
    RETURN IF($a IS NULL OR $b IS NULL, COALESCE($a, $b), ($a + $b) / 2.0);
};

-- Итоговая оценка аспекта: среднее двух проходов, округлённое ВНИЗ.
-- 4 и 5 -> 4.5 -> 4. Именно это число мы и ставим.
$score_final = ($dir, $rev, $md, $mr, $asp) -> {
    RETURN CAST(Math::Floor($avg2(
        $score($dir, $md, $asp),
        $score($rev, $mr, $asp)
    )) AS Int64);
};

-- clc_metrics одного прохода — то, что уходит в соответствующий raw_output.
$clc_pass = ($node, $model) -> {
    RETURN Just(Yson::From(<|
        clarity:    $score_int($node, $model, 'clarity'),
        liveliness: $score_int($node, $model, 'liveliness'),
        connect:    $score_int($node, $model, 'connect'),
        overall:    $score_int($node, $model, 'overall')
    |>));
};

-- clc_metrics для одного ответа целиком: четыре числа, ничего лишнего.
-- $md — ключ этого ответа в прямом прогоне, $mr — в обратном (там ответы переставлены).
$clc = ($dir, $rev, $md, $mr) -> {
    RETURN Just(Yson::From(<|
        clarity:    $score_final($dir, $rev, $md, $mr, 'clarity'),
        liveliness: $score_final($dir, $rev, $md, $mr, 'liveliness'),
        connect:    $score_final($dir, $rev, $md, $mr, 'connect'),
        overall:    $score_final($dir, $rev, $md, $mr, 'overall')
    |>));
};

-- Подробности по проходам и обоснования — отдельной колонкой, чтобы не засорять clc_metrics.
-- Обоснования храним от обоих проходов: у обратного они часто содержательнее.
$clc_detail = ($dir, $rev, $md, $mr) -> {
    RETURN Just(Yson::From(ToDict(ListMap($aspects, ($a) -> {
        RETURN AsTuple($a, Just(Yson::From(<|
            direct:            $score($dir, $md, $a),
            reversed:          $score($rev, $mr, $a),
            final:             $score_final($dir, $rev, $md, $mr, $a),
            reasoning_direct:  $score_why($dir, $md, $a),
            reasoning_reverse: $score_why($rev, $mr, $a)
        |>)));
    }))));
};

-- ========================= МАРКЕРЫ =========================
-- Структура первого этапа: {имя_маркера: {is_present: bool, explanation: string}}
$markers_plus = AsList(
    'empathy', 'subjectivity', 'tone_match', 'humor_metaphors'
);

$markers_minus = AsList(
    'critical_tone', 'bad_intro', 'bad_proactivity', 'over_emotional',
    'stuffy_bureaucratic', 'boundaries_violation', 'template_phrases',
    'language_errors', 'inconsistency'
);

$marker_names = ListExtend($markers_plus, $markers_minus);

$marker_on = ($m, $name) -> {
    RETURN Yson::ConvertToBool(Yson::Lookup(Yson::Lookup($m, $name), 'is_present')) ?? false;
};

$marker_why = ($m, $name) -> {
    RETURN Yson::LookupString(Yson::Lookup($m, $name), 'explanation') ?? '';
};

$present_in = ($m, $names) -> {
    RETURN ListFilter($names, ($n) -> { RETURN $marker_on($m, $n); });
};

-- список имён сработавших маркеров — удобно глазами и для группировок
$markers_list = ($m) -> { RETURN $present_in($m, $marker_names); };

-- нормализованный словарь: только флаги, без пояснений
$markers_flags = ($m) -> {
    RETURN Just(Yson::From(ToDict(ListMap($marker_names, ($n) -> {
        RETURN AsTuple($n, $marker_on($m, $n));
    }))));
};

-- пояснения — только по сработавшим, иначе тринадцать пустых строк на каждую пару
$markers_notes = ($m) -> {
    RETURN Just(Yson::From(ToDict(ListMap($markers_list($m), ($n) -> {
        RETURN AsTuple($n, $marker_why($m, $n));
    }))));
};

-- то, что читают глазами: плюсы, минусы и сколько их
$markers_pretty = ($m) -> {
    RETURN Just(Yson::From(<|
        plus:        $present_in($m, $markers_plus),
        minus:       $present_in($m, $markers_minus),
        plus_count:  ListLength($present_in($m, $markers_plus)),
        minus_count: ListLength($present_in($m, $markers_minus)),
        notes:       $markers_notes($m)
    |>));
};

-- чекбоксы в формате разметки.
-- tov_minus_addressing теперь берётся из inconsistency (раньше был захардкожен false).
-- tov_plus_clarity убран: маркера ясности больше не существует.
$markers_to_checkboxes = ($m) -> {
    RETURN Just(Yson::From(<|
        point_bad_intro:              $marker_on($m, 'bad_intro'),
        point_bad_proactivity:        $marker_on($m, 'bad_proactivity'),
        tov_minus_addressing:         $marker_on($m, 'inconsistency'),
        tov_minus_boundary_violation: $marker_on($m, 'boundaries_violation'),
        tov_minus_cliches:            $marker_on($m, 'template_phrases'),
        tov_minus_dry:                $marker_on($m, 'stuffy_bureaucratic'),
        tov_minus_language_errors:    $marker_on($m, 'language_errors'),
        tov_minus_overemotional:      $marker_on($m, 'over_emotional'),
        tov_plus_empathy:             $marker_on($m, 'empathy'),
        tov_plus_humor:               $marker_on($m, 'humor_metaphors'),
        tov_plus_subject:             $marker_on($m, 'subjectivity'),
        tov_plus_tone_match:          $marker_on($m, 'tone_match'),
        tov_tone_unacceptable:        $marker_on($m, 'critical_tone')
    |>));
};

-- ========================= ВЕРДИКТЫ =========================
-- tie / both_bad / skip / пустое — всё это ничья. Нормализуем сразу,
-- иначе 'tie' в прямом проходе против 'draw' в обратном считается расхождением
-- и пара уезжает в weak, хотя проходы согласны.
$norm = ($v) -> {
    RETURN CASE
        WHEN $v IS NULL                                    THEN 'draw'
        WHEN $v IN ('tie', 'both_bad', 'skip', 'draw', '') THEN 'draw'
        WHEN $v IN ('model_1', 'model_2')                  THEN $v
        ELSE 'draw'
    END;
};

$verdict = ($node) -> {
    RETURN $norm(Yson::LookupString(Yson::Lookup($node, 'sbs_comparison'), 'verdict'));
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

-- ========================= РАЗБОР =========================
$parsed = (
    SELECT
        d.*,

        $verdict(dst_yson_direct)            AS model_winner_direct,
        $verdict(dst_yson_reversed)          AS model_winner_reversed,
        $flip($verdict(dst_yson_reversed))   AS model_winner_reversed_normalized,

        -- метрики по каждому ответу: итог (среднее двух проходов) и каждый проход отдельно
        $clc(dst_yson_direct, dst_yson_reversed, 'model_1_evaluation', 'model_2_evaluation')        AS clc_metrics_1,
        $clc(dst_yson_direct, dst_yson_reversed, 'model_2_evaluation', 'model_1_evaluation')        AS clc_metrics_2,
        $clc_pass(dst_yson_direct,   'model_1_evaluation')                                          AS clc_direct_1,
        $clc_pass(dst_yson_direct,   'model_2_evaluation')                                          AS clc_direct_2,
        $clc_pass(dst_yson_reversed, 'model_2_evaluation')                                          AS clc_reversed_1,
        $clc_pass(dst_yson_reversed, 'model_1_evaluation')                                          AS clc_reversed_2,
        $clc_detail(dst_yson_direct, dst_yson_reversed, 'model_1_evaluation', 'model_2_evaluation') AS clc_detail_1,
        $clc_detail(dst_yson_direct, dst_yson_reversed, 'model_2_evaluation', 'model_1_evaluation') AS clc_detail_2,

        -- маркеры: списком имён, флагами и человекочитаемой сводкой
        $markers_list(mk1)                   AS markers_1_list,
        $markers_list(mk2)                   AS markers_2_list,
        $markers_flags(mk1)                  AS markers_1_flags,
        $markers_flags(mk2)                  AS markers_2_flags,
        $markers_notes(mk1)                  AS markers_1_notes,
        $markers_notes(mk2)                  AS markers_2_notes,
        $markers_pretty(mk1)                 AS markers_1,
        $markers_pretty(mk2)                 AS markers_2,

        Just(Yson::From(<|
            model_winner_direct:              $verdict(dst_yson_direct),
            model_winner_reversed:            $verdict(dst_yson_reversed),
            model_winner_reversed_normalized: $flip($verdict(dst_yson_reversed)),
            reasoning_direct:                 $sbs_why(dst_yson_direct),
            reasoning_reversed:               $sbs_why(dst_yson_reversed),
            direct_m1_overall:                $score(dst_yson_direct,   'model_1_evaluation', 'overall'),
            direct_m2_overall:                $score(dst_yson_direct,   'model_2_evaluation', 'overall'),
            reversed_m1_overall:              $score(dst_yson_reversed, 'model_2_evaluation', 'overall'),
            reversed_m2_overall:              $score(dst_yson_reversed, 'model_1_evaluation', 'overall'),
            parse_ok_direct:                  dst_yson_direct IS NOT NULL,
            parse_ok_reversed:                dst_yson_reversed IS NOT NULL,
            process_url:                      'https://nirvana.yandex-team.ru/process/9113ab38-0999-4125-b182-523e63252411',
            graph_owner:                      'kristisha'
        |>))                                 AS meta_info

    FROM (
        SELECT
            i1.*,
            $process_json(CAST(i1.dst_2 AS String)) AS dst_yson_direct,
            $process_json(CAST(i2.dst   AS String)) AS dst_yson_reversed,
            -- маркеры первого этапа берём из прямой таблицы: там ext_markers_1
            -- относится к answer_1, ext_markers_2 — к answer_2, без перестановок
            i1.ext_markers_1                        AS mk1,
            i1.ext_markers_2                        AS mk2,
            WITHOUT IF EXISTS i1.dst_yson_direct, i1.dst_yson_reversed, i1.mk1, i1.mk2
        FROM {{input1}} AS i1
        INNER JOIN {{input2}} AS i2
        USING (instruct_id)
    ) AS d

    -- входная таблица уже может нести колонки с этими именами: без WITHOUT будет
    -- дубликат имени в проекции и запрос не соберётся
    WITHOUT IF EXISTS
        d.meta_info,
        d.model_winner_direct, d.model_winner_reversed, d.model_winner_reversed_normalized,
        d.clc_metrics_1, d.clc_metrics_2,
        d.clc_direct_1, d.clc_direct_2, d.clc_reversed_1, d.clc_reversed_2,
        d.clc_detail_1, d.clc_detail_2,
        d.markers_1, d.markers_2,
        d.markers_1_list, d.markers_2_list,
        d.markers_1_flags, d.markers_2_flags,
        d.markers_1_notes, d.markers_2_notes
);

$winner_calc = (
    SELECT
        p.*,
        CASE
            WHEN model_winner_direct = model_winner_reversed_normalized
                THEN model_winner_direct
            WHEN model_winner_direct = 'draw'
                THEN model_winner_reversed_normalized
            WHEN model_winner_reversed_normalized = 'draw'
                THEN model_winner_direct
            ELSE 'draw'
        END AS tov_winner
    FROM $parsed AS p
    WITHOUT IF EXISTS p.tov_winner
);

-- ========================= СБОРКА РАЗМЕТКИ =========================
-- Обе структуры собраны именованными лямбдами над строкой целиком ($r = TableRow()),
-- чтобы один и тот же код уехал и в рабочую таблицу, и в отдельный выход.
-- Раньше они были расписаны инлайном в одном INSERT и переиспользовать их было нечем.

$agree = ($r) -> {
    RETURN $r.model_winner_direct = $r.model_winner_reversed_normalized;
};

-- raw_tov_markup — по одному raw_output на проход. Проходы обязаны отличаться:
-- в оценках стоят цифры своего прохода, не усреднённые.
-- Маркеры первого этапа общие для обоих: этап 1 прогонялся один раз.
$raw_markup = ($r) -> {
    RETURN Just(Yson::From(<|
        task_id:    COALESCE(CAST($r.instruct_id AS String), ''),
        pool_id:    $yson_null,
        project_id: $yson_null,
        answer_A:   COALESCE(CAST($r.answer_1 AS String), ''),
        answer_B:   COALESCE(CAST($r.answer_2 AS String), ''),
        source_A:   COALESCE(CAST($r.answer_source_1 AS String), ''),
        source_B:   COALESCE(CAST($r.answer_source_2 AS String), ''),
        checkboxes: Just(Yson::From(<||>)),
        markers:    $empty_list,

        raw_outputs: AsList(
            <|
                worker_id:        'direct',
                assignment_id:    $yson_null,
                assignment_link:  $yson_null,
                annotations:      $empty_list,
                checkboxes_A:     $markers_to_checkboxes($r.mk1),
                checkboxes_B:     $markers_to_checkboxes($r.mk2),
                clc_metrics_A:    $r.clc_direct_1,
                clc_metrics_B:    $r.clc_direct_2,
                markers_A:        $r.markers_1_list,
                markers_B:        $r.markers_2_list,
                comment_A:        $yson_null,
                comment_B:        $yson_null,
                general_comment:  $sbs_why($r.dst_yson_direct),
                comment_judge:    $yson_null,
                diff_pa:          $yson_null,
                diff_pa_winner:   $winner_source($r.model_winner_direct, $r.answer_source_1, $r.answer_source_2),
                direct_speech_A:  $yson_null,
                direct_speech_B:  $yson_null,
                markup_dt:        $yson_null,
                skip:             $yson_null,
                winner:           $winner_source($r.model_winner_direct, $r.answer_source_1, $r.answer_source_2)
            |>,
            <|
                worker_id:        'reverse',
                assignment_id:    $yson_null,
                assignment_link:  $yson_null,
                annotations:      $empty_list,
                checkboxes_A:     $markers_to_checkboxes($r.mk1),
                checkboxes_B:     $markers_to_checkboxes($r.mk2),
                -- в обратном прогоне ответы переставлены: A — это model_2_evaluation
                clc_metrics_A:    $r.clc_reversed_1,
                clc_metrics_B:    $r.clc_reversed_2,
                markers_A:        $r.markers_1_list,
                markers_B:        $r.markers_2_list,
                comment_A:        $yson_null,
                comment_B:        $yson_null,
                general_comment:  $sbs_why($r.dst_yson_reversed),
                comment_judge:    $yson_null,
                diff_pa:          $yson_null,
                diff_pa_winner:   $winner_source($r.model_winner_reversed_normalized, $r.answer_source_1, $r.answer_source_2),
                direct_speech_A:  $yson_null,
                direct_speech_B:  $yson_null,
                markup_dt:        $yson_null,
                skip:             $yson_null,
                winner:           $winner_source($r.model_winner_reversed_normalized, $r.answer_source_1, $r.answer_source_2)
            |>
        )
    |>));
};

-- agg_tov_markup — свёртка двух проходов: оценки усреднены, победитель уже сведён.
$agg_markup = ($r) -> {
    RETURN Just(Yson::From(<|
        task_id:    COALESCE(CAST($r.instruct_id AS String), ''),
        pool_id:    $yson_null,
        project_id: $yson_null,
        worker_ids: AsList('direct', 'reverse'),

        answer_A:   COALESCE(CAST($r.answer_1 AS String), ''),
        answer_B:   COALESCE(CAST($r.answer_2 AS String), ''),
        source_A:   COALESCE(CAST($r.answer_source_1 AS String), ''),
        source_B:   COALESCE(CAST($r.answer_source_2 AS String), ''),

        checkboxes_A: $markers_to_checkboxes($r.mk1),
        checkboxes_B: $markers_to_checkboxes($r.mk2),

        clc_metrics_A: $r.clc_metrics_1,
        clc_metrics_B: $r.clc_metrics_2,
        clc_detail_A:  $r.clc_detail_1,
        clc_detail_B:  $r.clc_detail_2,

        markers_A:       $r.markers_1_list,
        markers_B:       $r.markers_2_list,
        markers_notes_A: $r.markers_1_notes,
        markers_notes_B: $r.markers_2_notes,

        annotations:      AsList($empty_list, $empty_list),
        comments_A:       AsList('', ''),
        comments_B:       AsList('', ''),
        general_comments: AsList(
            $sbs_why($r.dst_yson_direct),
            $sbs_why($r.dst_yson_reversed)
        ),

        task_summarization: $yson_null,

        diff_pa:                  false,
        diff_pa_winner:           $winner_source($r.tov_winner, $r.answer_source_1, $r.answer_source_2),
        diff_pa_winner_agreement: IF($agree($r), 1.0, 0.0),
        diff_pa_winner_strength:  IF($agree($r), 'strong', 'weak'),

        direct_speech_A: false,
        direct_speech_B: false,

        winner:            $winner_source($r.tov_winner, $r.answer_source_1, $r.answer_source_2),
        winner_agreement:  IF($agree($r), 1.0, 0.0),
        winner_strength:   IF($agree($r), 'strong', 'weak'),

        skip: false
    |>));
};

-- ========================= ВЫХОД 1: рабочая таблица + разметка =========================
INSERT INTO {{output1}} WITH TRUNCATE
SELECT
    -- дополнительные колонки идут ДО wc.*: WITHOUT обязан быть последним в списке
    $agg_markup(TableRow())                                               AS agg_tov_markup,
    $raw_markup(TableRow())                                               AS raw_tov_markup,
    $winner_source(wc.tov_winner, wc.answer_source_1, wc.answer_source_2) AS tov_winner_source,
    IF($agree(TableRow()), 'strong', 'weak')                              AS tov_winner_strength,
    wc.*,
    WITHOUT IF EXISTS
        wc.agg_tov_markup, wc.raw_tov_markup,
        wc.dst, wc.dst_2, wc.dst_yson_direct, wc.dst_yson_reversed,
        wc.mk1, wc.mk2, wc.ext_markers_1, wc.ext_markers_2,
        wc.infer_dialog, wc.tov_prompt,
        wc.reasoning_dst, wc.reasoning_dst_2,
        wc.model_winner_direct, wc.model_winner_reversed, wc.model_winner_reversed_normalized
FROM $winner_calc AS wc;

-- ========================= ВЫХОД 2: только разметка =========================
-- Та же пара колонок отдельной узкой таблицей — под приклейку к исходным задачам
-- (см. sql/attach_tov_markup.sql). Если разметка нужна только в выходе 1,
-- этот INSERT можно выкинуть целиком.
INSERT INTO {{output2}} WITH TRUNCATE
SELECT
    wc.instruct_id          AS instruct_id,
    $raw_markup(TableRow()) AS raw_tov_markup,
    $agg_markup(TableRow()) AS agg_tov_markup
FROM $winner_calc AS wc;
