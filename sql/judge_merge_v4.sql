PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

DECLARE $input1 AS String;   -- прямой прогон второго этапа
DECLARE $input2 AS String;   -- обратный прогон второго этапа
DECLARE $input3 AS String;   -- исходник: answers, input_final_messages, input_meta, input_render_data
DECLARE $output1 AS String;
DECLARE $output2 AS String;
DECLARE $output3 AS String;  -- разбор целиком: исходник + raw_tov + out_tov

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
-- Структурой, а не Yson: этот же блок кладут ВНУТРЬ другого блока (выход 3),
-- и вложенный Yson там пришлось бы разворачивать вторым Yson::Parse.
$pointwise_struct = ($dir, $rev, $md, $mr) -> {
    RETURN <|
        clarity:    $aspect_block($dir, $rev, $md, $mr, 'clarity'),
        liveliness: $aspect_block($dir, $rev, $md, $mr, 'liveliness'),
        connect:    $aspect_block($dir, $rev, $md, $mr, 'connect'),
        overall:    $aspect_block($dir, $rev, $md, $mr, 'overall')
    |>;
};

$pointwise = ($dir, $rev, $md, $mr) -> {
    RETURN Just(Yson::From($pointwise_struct($dir, $rev, $md, $mr)));
};

-- Узел ответа джаджа целиком, как он пришёл в dst: model_N_evaluation со
-- звёздами и обоснованиями прохода. Ничего не пересобираем.
-- Serialize обязателен: Yson::Lookup отдаёт ресурс-ноду, а внутрь структуры,
-- которая уходит в Yson::From, класть можно только сам Yson.
$dst_node = ($y, $key) -> {
    RETURN Yson::Serialize(Yson::Lookup($y, $key));
};

-- Четыре числа без обвязки — формат разметки.
$clc_struct = ($dir, $rev, $md, $mr) -> {
    RETURN <|
        clarity:    $star($dir, $rev, $md, $mr, 'clarity'),
        liveliness: $star($dir, $rev, $md, $mr, 'liveliness'),
        connect:    $star($dir, $rev, $md, $mr, 'connect'),
        overall:    $star($dir, $rev, $md, $mr, 'overall')
    |>;
};

$clc = ($dir, $rev, $md, $mr) -> {
    RETURN Just(Yson::From($clc_struct($dir, $rev, $md, $mr)));
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

-- Что проход сказал про ОДИН ответ: summary аудита, маркеры и звёзды —
-- всё тремя кусками прямо из dst, без пересборки полей. Ключи внутри
-- ($review_key, $eval_key) разные у прямого и обратного прохода: в обратном
-- ответы переставлены, и answer_1 лежит под model_2.
$review = ($y, $review_key, $eval_key) -> {
    RETURN <|
        summary:   Yson::LookupString(Yson::Lookup($y, $review_key), 'summary') ?? '',
        markers:   Yson::Serialize($mk($y, $review_key)),
        pointwise: $dst_node($y, $eval_key)
    |>;
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
$flags_dict = ($d_mk, $r_mk) -> {
    RETURN ToDict(ListMap($marker_names, ($n) -> {
        RETURN AsTuple($n, $is_on($d_mk, $n) OR $is_on($r_mk, $n));
    }));
};

$marker_flags = ($d_mk, $r_mk) -> {
    RETURN Just(Yson::From($flags_dict($d_mk, $r_mk)));
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

-- Разметочные чекбоксы из словаря маркеров. Имена слева — интерфейс разметки,
-- менять их нельзя; справа — маркеры v4. tov_plus_clarity в этом списке нет:
-- в v4 ясность живёт в звёздах (clc_metrics), а не в маркерах.
-- Сигнатура как у $markers: два прохода, объединение по ИЛИ. Для чекбоксов
-- одного прохода передаём его же дважды.
$cb = ($d_mk, $r_mk, $n) -> {
    RETURN $is_on($d_mk, $n) OR $is_on($r_mk, $n);
};

$markers_to_checkboxes = ($d_mk, $r_mk) -> {
    RETURN Just(Yson::From(<|
        point_bad_intro:              $cb($d_mk, $r_mk, 'bad_intro'),
        point_bad_proactivity:        $cb($d_mk, $r_mk, 'bad_proactivity'),
        tov_minus_addressing:         $cb($d_mk, $r_mk, 'inconsistency'),
        tov_minus_boundary_violation: $cb($d_mk, $r_mk, 'boundaries_violation'),
        tov_minus_cliches:            $cb($d_mk, $r_mk, 'template_phrases'),
        tov_minus_dry:                $cb($d_mk, $r_mk, 'stuffy_bureaucratic'),
        tov_minus_language_errors:    $cb($d_mk, $r_mk, 'language_errors'),
        tov_minus_overemotional:      $cb($d_mk, $r_mk, 'over_emotional'),
        tov_plus_empathy:             $cb($d_mk, $r_mk, 'empathy'),
        tov_plus_humor:               $cb($d_mk, $r_mk, 'humor_metaphors'),
        tov_plus_subject:             $cb($d_mk, $r_mk, 'subjectivity'),
        tov_plus_tone_match:          $cb($d_mk, $r_mk, 'tone_match'),
        tov_tone_unacceptable:        $cb($d_mk, $r_mk, 'critical_tone')
    |>));
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
$as_source = ($w, $s1, $s2) -> {
    RETURN CASE $w
        WHEN 'model_1' THEN COALESCE(CAST($s1 AS String), 'model_1')
        WHEN 'model_2' THEN COALESCE(CAST($s2 AS String), 'model_2')
        ELSE 'draw'
    END;
};

-- Согласованность проходов — три состояния, а не два:
--   1.0 — оба назвали одного победителя (или оба сказали ничью);
--   0.5 — один назвал победителя, второй ничью: не спорят, просто один
--         проход осторожнее;
--   0.0 — назвали РАЗНЫХ победителей, то есть прямое противоречие.
-- Мешать 0.5 и 0.0 в одно «не сошлись» нельзя: это разные вещи, и именно
-- нули стоит смотреть руками.
$agreement = ($d, $r) -> {
    RETURN CASE
        WHEN $d = $r                                             THEN 1.0
        WHEN $d IN ('tie', 'draw') OR $r IN ('tie', 'draw')      THEN 0.5
        ELSE 0.0
    END;
};

$strength = ($d, $r) -> {
    RETURN CASE
        WHEN $d = $r                                             THEN 'strong'
        WHEN $d IN ('tie', 'draw') OR $r IN ('tie', 'draw')      THEN 'weak'
        ELSE 'conflict'
    END;
};

-- В формате разметки поле winner знает только имя сорса или 'draw', и пустую
-- строку вместо отсутствующего сорса — отсюда отдельная обёртка.
$winner_source = ($w, $s1, $s2) -> {
    RETURN CASE $w
        WHEN 'model_1' THEN COALESCE(CAST($s1 AS String), '')
        WHEN 'model_2' THEN COALESCE(CAST($s2 AS String), '')
        ELSE 'draw'
    END;
};

-- ========================= РАЗБОР =========================
-- Склейка по for_join: instruct_id по дороге переставал быть сквозным ключом
-- (на этапах разбора это просто нумерация строк таблицы), for_join же едет
-- из исходника неизменным и уникален в каждом прогоне.
$parsed = (
    SELECT
        i1.*,
        $process_json(CAST(i1.dst AS String)) AS dir_yson,
        $process_json(CAST(i2.dst AS String)) AS rev_yson
    FROM $input1 AS i1
    INNER JOIN $input2 AS i2
    USING (for_join)
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
            -- проходы назвали разных победителей — ничья.
            -- Что это было именно противоречие, а не честная ничья, видно
            -- по agreement: там 0.0, а не 0.5
            ELSE 'draw'
        END AS tov_winner
    FROM $calc AS c
);

-- ========================= ВЫХОД 1: рабочая таблица =========================
INSERT INTO $output1 WITH TRUNCATE
SELECT
    -- ---------- звёзды ----------
    $pointwise(f.dir_yson, f.rev_yson, 'model_1_evaluation', 'model_2_evaluation') AS pointwise_1,
    $pointwise(f.dir_yson, f.rev_yson, 'model_2_evaluation', 'model_1_evaluation') AS pointwise_2,
    $clc(f.dir_yson, f.rev_yson, 'model_1_evaluation', 'model_2_evaluation')       AS clc_metrics_1,
    $clc(f.dir_yson, f.rev_yson, 'model_2_evaluation', 'model_1_evaluation')       AS clc_metrics_2,

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
    Just(Yson::From(<|
        winner:            $as_source(f.tov_winner, f.answer_source_1, f.answer_source_2),
        winner_model:      f.tov_winner,
        direct:            $as_source(f.w_direct, f.answer_source_1, f.answer_source_2),
        reversed:          $as_source(f.w_reversed_norm, f.answer_source_1, f.answer_source_2),
        agreement:         $agreement(f.w_direct, f.w_reversed_norm),
        strength:          $strength(f.w_direct, f.w_reversed_norm),
        reasoning_direct:  $sbs_why(f.dir_yson),
        reasoning_reversed: $sbs_why(f.rev_yson)
    |>))                                     AS sbs,

    -- плоско, чтобы фильтровать и группировать без Yson::Lookup
    $as_source(f.tov_winner, f.answer_source_1, f.answer_source_2) AS tov_winner_source,

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
    -- Первый блок — служебное этого запроса, второй — колонки, которые мы
    -- только что пересчитали: они уже есть во входной таблице с прошлых
    -- этапов, и без снятия YQL падает с «Duplicated member».
    f.* WITHOUT IF EXISTS
        f.dir_yson, f.rev_yson, f.pass_order,
        f.mk1_dir, f.mk2_dir, f.mk1_rev, f.mk2_rev,
        f.w_direct, f.w_reversed_norm,
        f.dst, f.reasoning_dst, f.infer_dialog, f.tov_prompt, f._other,

        f.pointwise_1, f.pointwise_2,
        f.clc_metrics_1, f.clc_metrics_2,
        f.markers_1, f.markers_2,
        f.markers_1_flags, f.markers_2_flags,
        f.markers_1_list, f.markers_2_list,
        f.markers_1_agreement, f.markers_2_agreement,
        f.sbs, f.tov_winner_source, f.meta_info
FROM $final AS f;

-- ========================= ВЫХОД 2: формат разметки =========================
-- task_id — for_join: он единственный ключ, который едет из исходника до конца
-- неизменным, по нему же разметку потом класть обратно.
INSERT INTO $output2 WITH TRUNCATE
SELECT
    f.for_join     AS for_join,
    f.instruct_id  AS instruct_id,

    Just(Yson::From(<|
        task_id:    COALESCE(CAST(f.for_join AS String), ''),
        pool_id:    $yson_null,
        project_id: $yson_null,
        answer_A:   COALESCE(CAST(f.answer_1 AS String), ''),
        answer_B:   COALESCE(CAST(f.answer_2 AS String), ''),
        source_A:   COALESCE(CAST(f.answer_source_1 AS String), ''),
        source_B:   COALESCE(CAST(f.answer_source_2 AS String), ''),
        checkboxes: Just(Yson::From(<||>)),
        markers:    Just(Yson::From(AsList())),

        raw_outputs: AsList(
            <|
                worker_id:       'direct',
                assignment_id:   $yson_null,
                annotations:     Just(Yson::From(AsList())),
                checkboxes_A:    $markers_to_checkboxes(f.mk1_dir, f.mk1_dir),
                checkboxes_B:    $markers_to_checkboxes(f.mk2_dir, f.mk2_dir),
                pointwise_A:     $clc(f.dir_yson, f.dir_yson, 'model_1_evaluation', 'model_1_evaluation'),
                pointwise_B:     $clc(f.dir_yson, f.dir_yson, 'model_2_evaluation', 'model_2_evaluation'),
                comment_A:       COALESCE(CAST(f.model_1_analysis AS String), ''),
                comment_B:       COALESCE(CAST(f.model_2_analysis AS String), ''),
                general_comment: $sbs_why(f.dir_yson),
                comment_judge:   $yson_null,
                diff_pa:         $yson_null,
                diff_pa_winner:  $winner_source(f.w_direct, f.answer_source_1, f.answer_source_2),
                direct_speech_A: $yson_null,
                direct_speech_B: $yson_null,
                markup_dt:       $yson_null,
                skip:            $yson_null,
                winner:          $winner_source(f.w_direct, f.answer_source_1, f.answer_source_2)
            |>,
            -- обратный проход уже нормализован: mk1_rev — это разметка answer_1,
            -- то есть model_2_markers_review сырого ответа. Ставить сюда
            -- model_1 нельзя, A и B поменяются местами
            <|
                worker_id:       'reverse',
                assignment_id:   $yson_null,
                annotations:     Just(Yson::From(AsList())),
                checkboxes_A:    $markers_to_checkboxes(f.mk1_rev, f.mk1_rev),
                checkboxes_B:    $markers_to_checkboxes(f.mk2_rev, f.mk2_rev),
                pointwise_A:     $clc(f.rev_yson, f.rev_yson, 'model_2_evaluation', 'model_2_evaluation'),
                pointwise_B:     $clc(f.rev_yson, f.rev_yson, 'model_1_evaluation', 'model_1_evaluation'),
                comment_A:       COALESCE(CAST(f.model_1_linguistic_scan AS String), ''),
                comment_B:       COALESCE(CAST(f.model_2_linguistic_scan AS String), ''),
                general_comment: $sbs_why(f.rev_yson),
                comment_judge:   $yson_null,
                diff_pa:         $yson_null,
                diff_pa_winner:  $winner_source(f.w_reversed_norm, f.answer_source_1, f.answer_source_2),
                direct_speech_A: $yson_null,
                direct_speech_B: $yson_null,
                markup_dt:       $yson_null,
                skip:            $yson_null,
                winner:          $winner_source(f.w_reversed_norm, f.answer_source_1, f.answer_source_2)
            |>
        )
    |>)) AS raw_tov_markup,

    Just(Yson::From(<|
        task_id:    COALESCE(CAST(f.for_join AS String), ''),
        pool_id:    $yson_null,
        project_id: $yson_null,
        worker_ids: AsList('direct', 'reverse'),

        answer_A:   COALESCE(CAST(f.answer_1 AS String), ''),
        answer_B:   COALESCE(CAST(f.answer_2 AS String), ''),
        source_A:   COALESCE(CAST(f.answer_source_1 AS String), ''),
        source_B:   COALESCE(CAST(f.answer_source_2 AS String), ''),

        -- сводные чекбоксы: маркер стоит, если его увидел хотя бы один проход
        checkboxes_A: $markers_to_checkboxes(f.mk1_dir, f.mk1_rev),
        checkboxes_B: $markers_to_checkboxes(f.mk2_dir, f.mk2_rev),

        pointwise_A: $clc(f.dir_yson, f.rev_yson, 'model_1_evaluation', 'model_2_evaluation'),
        pointwise_B: $clc(f.dir_yson, f.rev_yson, 'model_2_evaluation', 'model_1_evaluation'),

        markers_A: $marker_list(f.mk1_dir, f.mk1_rev),
        markers_B: $marker_list(f.mk2_dir, f.mk2_rev),

        annotations:      AsList(AsList(), AsList()),
        -- список позиционный, по элементу на воркера из worker_ids. Черновик
        -- у обоих проходов общий, поэтому вместо копии во второй позиции —
        -- лингвистический скан: разные куски разбора вместо одного дважды
        comments_A: AsList(
            COALESCE(CAST(f.model_1_analysis AS String), ''),
            COALESCE(CAST(f.model_1_linguistic_scan AS String), '')
        ),
        comments_B: AsList(
            COALESCE(CAST(f.model_2_analysis AS String), ''),
            COALESCE(CAST(f.model_2_linguistic_scan AS String), '')
        ),
        general_comments: AsList($sbs_why(f.dir_yson), $sbs_why(f.rev_yson)),

        task_summarization: $yson_null,

        diff_pa:                  false,
        diff_pa_winner:           $winner_source(f.tov_winner, f.answer_source_1, f.answer_source_2),
        diff_pa_winner_agreement: $agreement(f.w_direct, f.w_reversed_norm),
        diff_pa_winner_strength:  $strength(f.w_direct, f.w_reversed_norm),

        direct_speech_A: false,
        direct_speech_B: false,

        winner:           $winner_source(f.tov_winner, f.answer_source_1, f.answer_source_2),
        winner_agreement: $agreement(f.w_direct, f.w_reversed_norm),
        winner_strength:  $strength(f.w_direct, f.w_reversed_norm),

        skip: false
    |>)) AS agg_tov_markup

FROM $final AS f;

-- ========================= ВЫХОД 3: исходник + разбор =========================
-- Одна строка = одна пара: слева поля исходника как они лежат в $input3,
-- справа две колонки разбора.
--   raw_tov — сырьё, ровно три ключа: common, direct, reverse;
--   out_tov — итог: четыре числа на ответ, флаги маркеров, победитель.
--
-- Раскладка внутри raw_tov: в блоке прохода лежит ответ джаджа как есть,
-- разложенный по ответам, — review_A и review_B это summary, маркеры и
-- звёзды прямо из dst, со всеми обоснованиями. Отдельно из sbs_comparison
-- вынут победитель: сразу сорсом, а не «model_1», и его обоснование рядом.
-- В common то, что относится к паре целиком: маркеры и разбор первого
-- этапа и сведённые по двум проходам звёзды.
--
-- Ключей в выходе нет: instruct_id и так лежит в input_meta, а склейка идёт
-- по for_join — колонкой он наружу не едет, только джойнит.
--
-- LEFT JOIN, а не INNER: если строки в исходнике не нашлось, разбор всё равно
-- должен доехать — пустой input_meta виден глазами, пропавшая строка нет.
INSERT INTO $output3 WITH TRUNCATE
SELECT
    -- ---------- исходник, отдельными колонками ----------
    i3.answers              AS answers,
    i3.input_final_messages AS input_final_messages,
    i3.input_meta           AS input_meta,
    i3.input_render_data    AS input_render_data,

    -- ---------- сырьё ----------
    Just(Yson::From(<|
        common: <|
            -- маркеры первого этапа, колонкой как есть
            markers_A: f.markers_1_answer,
            markers_B: f.markers_2_answer,

            -- разбор первого этапа: у проходов он общий
            analysis_A:        COALESCE(CAST(f.model_1_analysis AS String), ''),
            analysis_B:        COALESCE(CAST(f.model_2_analysis AS String), ''),
            linguistic_scan_A: COALESCE(CAST(f.model_1_linguistic_scan AS String), ''),
            linguistic_scan_B: COALESCE(CAST(f.model_2_linguistic_scan AS String), ''),

            -- звёзды колонкой как есть, ничего не пересчитываем
            pointwise_A: f.pointwise_1,
            pointwise_B: f.pointwise_2
        |>,
        direct: <|
            winner:           $winner_source(f.w_direct, f.answer_source_1, f.answer_source_2),
            winner_reasoning: $sbs_why(f.dir_yson),
            review_A:         $review(f.dir_yson, 'model_1_markers_review', 'model_1_evaluation'),
            review_B:         $review(f.dir_yson, 'model_2_markers_review', 'model_2_evaluation')
        |>,
        -- в обратном проходе ответы переставлены: answer_1 лежит под model_2.
        -- Раскладываем по A и B, а не по model_N, иначе блоки нельзя ставить
        -- рядом. Победитель по той же причине уже развёрнут
        reverse: <|
            winner:           $winner_source(f.w_reversed_norm, f.answer_source_1, f.answer_source_2),
            winner_reasoning: $sbs_why(f.rev_yson),
            review_A:         $review(f.rev_yson, 'model_2_markers_review', 'model_2_evaluation'),
            review_B:         $review(f.rev_yson, 'model_1_markers_review', 'model_1_evaluation')
        |>
    |>)) AS raw_tov,

    -- ---------- итог ----------
    Just(Yson::From(<|
        source_A: COALESCE(CAST(f.answer_source_1 AS String), ''),
        source_B: COALESCE(CAST(f.answer_source_2 AS String), ''),

        -- четыре конечных числа на ответ, без обвязки
        pointwise_A: $clc_struct(f.dir_yson, f.rev_yson, 'model_1_evaluation', 'model_2_evaluation'),
        pointwise_B: $clc_struct(f.dir_yson, f.rev_yson, 'model_2_evaluation', 'model_1_evaluation'),

        -- словарь флагов: имя маркера -> bool, ничего кроме
        markers_A: $flags_dict(f.mk1_dir, f.mk1_rev),
        markers_B: $flags_dict(f.mk2_dir, f.mk2_rev),

        winner: $winner_source(f.tov_winner, f.answer_source_1, f.answer_source_2),

        -- согласованность проходов: по ней и отбирают строки на ручной просмотр
        winner_agreement: $agreement(f.w_direct, f.w_reversed_norm),
        winner_strength:  $strength(f.w_direct, f.w_reversed_norm)
    |>)) AS out_tov

FROM $final AS f
LEFT JOIN $input3 AS i3
ON f.for_join == i3.for_join;
