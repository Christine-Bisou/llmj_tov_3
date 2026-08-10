PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

DECLARE $input1 AS String;   -- прямой прогон второго этапа
DECLARE $input2 AS String;   -- обратный прогон второго этапа
DECLARE $input3 AS String;   -- исходник: answers, input_final_messages, input_meta, input_render_data
DECLARE $input4 AS String;   -- дополнительный джадж по речевым ошибкам, ключ for_join
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

-- Маркер, который добирает дополнительный джадж, и текст пометки о нём.
-- Если доп. джадж поедет по другому маркеру — меняется только эта строка.
$extra_marker = 'language_errors';
$extra_note   = 'Найдено дополнительным джаджом по речевым ошибкам.';

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

-- Везде AsStruct, а не короткая запись <| |>: она разбирается не во всех
-- версиях YQL. Значение то же самое, только имя поля пишется справа.
$aspect_block = ($dir, $rev, $md, $mr, $asp) -> {
    RETURN AsStruct(
        $star($dir, $rev, $md, $mr, $asp)   AS score,
        $avg($dir, $rev, $md, $mr, $asp)    AS avg,
        $score($dir, $md, $asp)             AS direct,
        $score($rev, $mr, $asp)             AS reversed,
        $reason($dir, $md, $asp)            AS reasoning
    );
};

-- $md — ключ этого ответа в прямом проходе, $mr — в обратном (там всё зеркально).
-- Структурой, а не Yson: этот же блок кладут ВНУТРЬ другого блока (выход 3),
-- и вложенный Yson там пришлось бы разворачивать вторым Yson::Parse.
$pointwise_struct = ($dir, $rev, $md, $mr) -> {
    RETURN AsStruct(
        $aspect_block($dir, $rev, $md, $mr, 'clarity')    AS clarity,
        $aspect_block($dir, $rev, $md, $mr, 'liveliness') AS liveliness,
        $aspect_block($dir, $rev, $md, $mr, 'connect')    AS connect,
        $aspect_block($dir, $rev, $md, $mr, 'overall')    AS overall
    );
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
    RETURN AsStruct(
        $star($dir, $rev, $md, $mr, 'clarity')    AS clarity,
        $star($dir, $rev, $md, $mr, 'liveliness') AS liveliness,
        $star($dir, $rev, $md, $mr, 'connect')    AS connect,
        $star($dir, $rev, $md, $mr, 'overall')    AS overall
    );
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
    RETURN AsStruct(
        (Yson::LookupString(Yson::Lookup($y, $review_key), 'summary') ?? '') AS summary,
        Yson::Serialize($mk($y, $review_key))                                AS markers,
        $dst_node($y, $eval_key)                                             AS pointwise
    );
};

-- ===================== ДОПОЛНИТЕЛЬНЫЙ ДЖАДЖ ПО РЕЧЕВЫМ =====================
-- Основной джадж речевые ошибки пропускает, поэтому по той же паре гоняется
-- отдельный прогон ($input4, ключ for_join). Правило простое: если доп. джадж
-- сказал true, а оба основных прохода — false, маркер всё равно ставим и в
-- explanation пишем, что нашёл его доп. джадж. Обратно (снять маркер, который
-- увидели основные проходы) он не работает: это добор полноты, а не вето.
--
-- ЕДИНСТВЕННОЕ место, которое знает формат $input4. Сырой выход джаджа лежит
-- в колонке dst, как у $input1/$input2, и внутри разложен так:
--   {model_N_scan: "...", model_N_markers: {language_errors: {is_present, explanation}}}
-- Маркер там ровно один, звёзд и вердикта нет.
$extra_mk = ($y, $markers_key) -> {
    RETURN Yson::Lookup($y, $markers_key);
};

$extra_on = ($mk_node) -> {
    RETURN Yson::ConvertToBool(
        Yson::Lookup(Yson::Lookup($mk_node, 'language_errors'), 'is_present')
    ) ?? false;
};

$extra_why = ($mk_node) -> {
    RETURN Yson::LookupString(
        Yson::Lookup($mk_node, 'language_errors'), 'explanation'
    ) ?? '';
};

$extra_scan = ($y, $scan_key) -> {
    RETURN Yson::LookupString($y, $scan_key) ?? '';
};

$extra_parsed = (
    SELECT
        for_join                              AS for_join,
        $process_json(CAST(dst AS String))    AS ext_yson
    FROM $input4
);

-- A — это answer_1, B — answer_2: доп. джадж гоняется в прямом порядке,
-- переставлять ничего не надо.
$extra = (
    SELECT
        e.for_join AS for_join,
        $extra_on($extra_mk(e.ext_yson, 'model_1_markers'))  AS speech_extra_A,
        $extra_on($extra_mk(e.ext_yson, 'model_2_markers'))  AS speech_extra_B,
        $extra_why($extra_mk(e.ext_yson, 'model_1_markers')) AS speech_extra_A_why,
        $extra_why($extra_mk(e.ext_yson, 'model_2_markers')) AS speech_extra_B_why,
        -- пословный проход джаджа: в объединение не идёт, но в разбор кладём —
        -- по нему видно, что он вообще смотрел
        $extra_scan(e.ext_yson, 'model_1_scan')              AS speech_extra_A_scan,
        $extra_scan(e.ext_yson, 'model_2_scan')              AS speech_extra_B_scan
    FROM $extra_parsed AS e
);

-- Что проход(ы) плюс доп. джадж дали по одному маркеру.
$on_with_extra = ($d_mk, $r_mk, $n, $ext_on) -> {
    RETURN $is_on($d_mk, $n) OR $is_on($r_mk, $n) OR ($n == $extra_marker AND $ext_on);
};

-- Маркер считаем выставленным, если его увидел ХОТЯ БЫ один проход:
-- пропуск маркера — настоящая ошибка, лишнее срабатывание видно по in_direct /
-- in_reversed и по agreed, так что объединение ничего не прячет. Доп. джадж
-- добавлен в то же объединение и отдельно виден по in_extra /
-- found_by_extra_judge.
$markers = ($d_mk, $r_mk, $ext_on, $ext_why) -> {
    RETURN Just(Yson::From(ToDict(ListMap($marker_names, ($n) -> {
        $in_d       = $is_on($d_mk, $n);
        $in_r       = $is_on($r_mk, $n);
        $in_extra   = ($n == $extra_marker) AND $ext_on;
        -- маркер стоит ТОЛЬКО потому, что его нашёл доп. джадж
        $from_extra = $in_extra AND NOT ($in_d OR $in_r);
        RETURN AsTuple($n, AsStruct(
            ($in_d OR $in_r OR $in_extra) AS is_present,
            $in_d       AS in_direct,
            $in_r       AS in_reversed,
            $in_extra   AS in_extra,
            $from_extra AS found_by_extra_judge,
            -- согласие считаем по двум основным проходам: доп. джадж — не проход,
            -- он смотрит один маркер и голосует только в плюс
            ($in_d == $in_r) AS agreed,
            IF($audit($d_mk, $n) != '', $audit($d_mk, $n), $audit($r_mk, $n)) AS audit,
            IF($from_extra,
               IF($ext_why != '', $extra_note || ' ' || $ext_why, $extra_note),
               IF($in_d, $why($d_mk, $n), $why($r_mk, $n))) AS explanation
        ));
    }))));
};

-- Только флаги, без пояснений — для метрик и джойнов с золотом.
$flags_dict = ($d_mk, $r_mk, $ext_on) -> {
    RETURN ToDict(ListMap($marker_names, ($n) -> {
        RETURN AsTuple($n, $on_with_extra($d_mk, $r_mk, $n, $ext_on));
    }));
};

$marker_flags = ($d_mk, $r_mk, $ext_on) -> {
    RETURN Just(Yson::From($flags_dict($d_mk, $r_mk, $ext_on)));
};

$marker_list = ($d_mk, $r_mk, $ext_on) -> {
    RETURN ListFilter($marker_names, ($n) -> {
        RETURN $on_with_extra($d_mk, $r_mk, $n, $ext_on);
    });
};

-- Доля маркеров, по которым сошлись ОСНОВНЫЕ проходы: низкая — повод
-- посмотреть строку руками. Доп. джадж сюда не входит: он судит один маркер,
-- и его добор испортил бы шкалу.
$marker_agreement = ($d_mk, $r_mk) -> {
    RETURN CAST(ListLength(ListFilter($marker_names, ($n) -> {
        RETURN $is_on($d_mk, $n) == $is_on($r_mk, $n);
    })) AS Double) / CAST(ListLength($marker_names) AS Double);
};

-- Разметочные чекбоксы из словаря маркеров. Имена слева — интерфейс разметки,
-- менять их нельзя; справа — маркеры v4. tov_plus_clarity в этом списке нет:
-- в v4 ясность живёт в звёздах (clc_metrics), а не в маркерах.
-- Сигнатура как у $markers: два прохода, объединение по ИЛИ. Для чекбоксов
-- одного прохода передаём его же дважды, а доп. джадж — false: в блоке прохода
-- должно лежать то, что сказал именно он.
$cb = ($d_mk, $r_mk, $n) -> {
    RETURN $is_on($d_mk, $n) OR $is_on($r_mk, $n);
};

$markers_to_checkboxes = ($d_mk, $r_mk, $ext_on) -> {
    RETURN Just(Yson::From(AsStruct(
        $cb($d_mk, $r_mk, 'bad_intro')            AS point_bad_intro,
        $cb($d_mk, $r_mk, 'bad_proactivity')      AS point_bad_proactivity,
        $cb($d_mk, $r_mk, 'inconsistency')        AS tov_minus_addressing,
        $cb($d_mk, $r_mk, 'boundaries_violation') AS tov_minus_boundary_violation,
        $cb($d_mk, $r_mk, 'template_phrases')     AS tov_minus_cliches,
        $cb($d_mk, $r_mk, 'stuffy_bureaucratic')  AS tov_minus_dry,
        -- единственный чекбокс, который может доставить доп. джадж
        $on_with_extra($d_mk, $r_mk, 'language_errors', $ext_on) AS tov_minus_language_errors,
        $cb($d_mk, $r_mk, 'over_emotional')       AS tov_minus_overemotional,
        $cb($d_mk, $r_mk, 'empathy')              AS tov_plus_empathy,
        $cb($d_mk, $r_mk, 'humor_metaphors')      AS tov_plus_humor,
        $cb($d_mk, $r_mk, 'subjectivity')         AS tov_plus_subject,
        $cb($d_mk, $r_mk, 'tone_match')           AS tov_plus_tone_match,
        $cb($d_mk, $r_mk, 'critical_tone')        AS tov_tone_unacceptable
    )));
};

-- Блок про речевые целиком: флаг, откуда он взялся и обоснование доп. джаджа.
$speech_block = ($d_mk, $r_mk, $ext_on, $ext_why) -> {
    RETURN AsStruct(
        $on_with_extra($d_mk, $r_mk, 'language_errors', $ext_on) AS is_present,
        $cb($d_mk, $r_mk, 'language_errors')                     AS in_passes,
        $ext_on                                                  AS in_extra_judge,
        ($ext_on AND NOT $cb($d_mk, $r_mk, 'language_errors'))   AS found_by_extra_judge,
        IF($ext_on AND NOT $cb($d_mk, $r_mk, 'language_errors'),
           IF($ext_why != '', $extra_note || ' ' || $ext_why, $extra_note),
           IF($is_on($d_mk, 'language_errors'),
              $why($d_mk, 'language_errors'),
              $why($r_mk, 'language_errors')))                   AS reasoning
    );
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

-- LEFT JOIN: доп. джадж мог отработать не по всем парам — там, где его нет,
-- флаг остаётся false и всё считается как раньше.
$parsed_extra = (
    SELECT
        COALESCE(x.speech_extra_A,     false) AS speech_extra_A,
        COALESCE(x.speech_extra_B,     false) AS speech_extra_B,
        COALESCE(x.speech_extra_A_why, '')    AS speech_extra_A_why,
        COALESCE(x.speech_extra_B_why, '')    AS speech_extra_B_why,
        COALESCE(x.speech_extra_A_scan, '')   AS speech_extra_A_scan,
        COALESCE(x.speech_extra_B_scan, '')   AS speech_extra_B_scan,
        -- колонки могли остаться от прошлого прогона доп. джаджа: снимаем,
        -- иначе алиасы выше упрутся в «Duplicated member»
        p.* WITHOUT IF EXISTS
            p.speech_extra_A, p.speech_extra_B,
            p.speech_extra_A_why, p.speech_extra_B_why,
            p.speech_extra_A_scan, p.speech_extra_B_scan
    FROM $parsed AS p
    LEFT JOIN $extra AS x
    ON p.for_join == x.for_join
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
    FROM $parsed_extra AS p
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
    -- речевые здесь уже с добором доп. джаджа: внутри markers_N видно,
    -- кто именно поставил маркер (in_direct / in_reversed / in_extra)
    $markers(f.mk1_dir, f.mk1_rev, f.speech_extra_A, f.speech_extra_A_why) AS markers_1,
    $markers(f.mk2_dir, f.mk2_rev, f.speech_extra_B, f.speech_extra_B_why) AS markers_2,
    $marker_flags(f.mk1_dir, f.mk1_rev, f.speech_extra_A)                  AS markers_1_flags,
    $marker_flags(f.mk2_dir, f.mk2_rev, f.speech_extra_B)                  AS markers_2_flags,
    $marker_list(f.mk1_dir, f.mk1_rev, f.speech_extra_A)                   AS markers_1_list,
    $marker_list(f.mk2_dir, f.mk2_rev, f.speech_extra_B)                   AS markers_2_list,
    $marker_agreement(f.mk1_dir, f.mk1_rev)                                AS markers_1_agreement,
    $marker_agreement(f.mk2_dir, f.mk2_rev)                                AS markers_2_agreement,

    -- плоско: по этим двум колонкам сразу видно, сколько маркеров добрал
    -- доп. джадж и не сломал ли он метрику
    Just(Yson::From($speech_block(f.mk1_dir, f.mk1_rev, f.speech_extra_A, f.speech_extra_A_why))) AS speech_check_1,
    Just(Yson::From($speech_block(f.mk2_dir, f.mk2_rev, f.speech_extra_B, f.speech_extra_B_why))) AS speech_check_2,

    -- ---------- вердикт ----------
    Just(Yson::From(AsStruct(
        $as_source(f.tov_winner, f.answer_source_1, f.answer_source_2)      AS winner,
        f.tov_winner                                                        AS winner_model,
        $as_source(f.w_direct, f.answer_source_1, f.answer_source_2)        AS direct,
        $as_source(f.w_reversed_norm, f.answer_source_1, f.answer_source_2) AS reversed,
        $agreement(f.w_direct, f.w_reversed_norm)                           AS agreement,
        $strength(f.w_direct, f.w_reversed_norm)                            AS strength,
        $sbs_why(f.dir_yson)                                                AS reasoning_direct,
        $sbs_why(f.rev_yson)                                                AS reasoning_reversed
    )))                                      AS sbs,

    -- плоско, чтобы фильтровать и группировать без Yson::Lookup
    $as_source(f.tov_winner, f.answer_source_1, f.answer_source_2) AS tov_winner_source,

    Just(Yson::From(AsStruct(
        f.w_direct                                            AS model_winner_direct,
        f.w_reversed_norm                                     AS model_winner_reversed_normalized,
        $sbs_why(f.dir_yson)                                  AS reasoning_direct,
        $sbs_why(f.rev_yson)                                  AS reasoning_reversed,
        $score(f.dir_yson, 'model_1_evaluation', 'overall')    AS direct_m1_overall,
        $score(f.dir_yson, 'model_2_evaluation', 'overall')    AS direct_m2_overall,
        $score(f.rev_yson, 'model_2_evaluation', 'overall')    AS reversed_m1_overall,
        $score(f.rev_yson, 'model_1_evaluation', 'overall')    AS reversed_m2_overall,
        'https://nirvana.yandex-team.ru/process/9113ab38-0999-4125-b182-523e63252411' AS process_url,
        'kristisha'                                           AS graph_owner
    )))                                      AS meta_info,

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
        f.speech_check_1, f.speech_check_2,
        f.sbs, f.tov_winner_source, f.meta_info
FROM $final AS f;

-- ========================= ВЫХОД 2: формат разметки =========================
-- task_id — for_join: он единственный ключ, который едет из исходника до конца
-- неизменным, по нему же разметку потом класть обратно.
INSERT INTO $output2 WITH TRUNCATE
SELECT
    f.for_join     AS for_join,
    f.instruct_id  AS instruct_id,

    Just(Yson::From(AsStruct(
        COALESCE(CAST(f.for_join AS String), '')        AS task_id,
        $yson_null                                      AS pool_id,
        $yson_null                                      AS project_id,
        COALESCE(CAST(f.answer_1 AS String), '')        AS answer_A,
        COALESCE(CAST(f.answer_2 AS String), '')        AS answer_B,
        COALESCE(CAST(f.answer_source_1 AS String), '') AS source_A,
        COALESCE(CAST(f.answer_source_2 AS String), '') AS source_B,
        Just(Yson::From(AsStruct()))                    AS checkboxes,
        Just(Yson::From(AsList()))                      AS markers,

        AsList(
            -- в блоке прохода лежит то, что сказал именно он: доп. джадж сюда
            -- не подмешиваем (третий аргумент false), иначе в raw пропадёт
            -- разница между проходом и добором
            AsStruct(
                'direct'                                                     AS worker_id,
                $yson_null                                                   AS assignment_id,
                Just(Yson::From(AsList()))                                   AS annotations,
                $markers_to_checkboxes(f.mk1_dir, f.mk1_dir, false)          AS checkboxes_A,
                $markers_to_checkboxes(f.mk2_dir, f.mk2_dir, false)          AS checkboxes_B,
                $clc(f.dir_yson, f.dir_yson, 'model_1_evaluation', 'model_1_evaluation') AS pointwise_A,
                $clc(f.dir_yson, f.dir_yson, 'model_2_evaluation', 'model_2_evaluation') AS pointwise_B,
                COALESCE(CAST(f.model_1_analysis AS String), '')             AS comment_A,
                COALESCE(CAST(f.model_2_analysis AS String), '')             AS comment_B,
                $sbs_why(f.dir_yson)                                         AS general_comment,
                $yson_null                                                   AS comment_judge,
                $yson_null                                                   AS diff_pa,
                $winner_source(f.w_direct, f.answer_source_1, f.answer_source_2) AS diff_pa_winner,
                $yson_null                                                   AS direct_speech_A,
                $yson_null                                                   AS direct_speech_B,
                $yson_null                                                   AS markup_dt,
                $yson_null                                                   AS skip,
                $winner_source(f.w_direct, f.answer_source_1, f.answer_source_2) AS winner
            ),
            -- обратный проход уже нормализован: mk1_rev — это разметка answer_1,
            -- то есть model_2_markers_review сырого ответа. Ставить сюда
            -- model_1 нельзя, A и B поменяются местами
            AsStruct(
                'reverse'                                                    AS worker_id,
                $yson_null                                                   AS assignment_id,
                Just(Yson::From(AsList()))                                   AS annotations,
                $markers_to_checkboxes(f.mk1_rev, f.mk1_rev, false)          AS checkboxes_A,
                $markers_to_checkboxes(f.mk2_rev, f.mk2_rev, false)          AS checkboxes_B,
                $clc(f.rev_yson, f.rev_yson, 'model_2_evaluation', 'model_2_evaluation') AS pointwise_A,
                $clc(f.rev_yson, f.rev_yson, 'model_1_evaluation', 'model_1_evaluation') AS pointwise_B,
                COALESCE(CAST(f.model_1_linguistic_scan AS String), '')      AS comment_A,
                COALESCE(CAST(f.model_2_linguistic_scan AS String), '')      AS comment_B,
                $sbs_why(f.rev_yson)                                         AS general_comment,
                $yson_null                                                   AS comment_judge,
                $yson_null                                                   AS diff_pa,
                $winner_source(f.w_reversed_norm, f.answer_source_1, f.answer_source_2) AS diff_pa_winner,
                $yson_null                                                   AS direct_speech_A,
                $yson_null                                                   AS direct_speech_B,
                $yson_null                                                   AS markup_dt,
                $yson_null                                                   AS skip,
                $winner_source(f.w_reversed_norm, f.answer_source_1, f.answer_source_2) AS winner
            )
            -- третьим блоком доп. джадж сюда не встаёт: raw_outputs — список
            -- структур одного типа, а у джаджа по речевым нет ни чекбоксов, ни
            -- звёзд, ни вердикта. Пустой блок читался бы как «джадж сказал нет
            -- по всем маркерам». Его ответ лежит в speech_check_A/B ниже
        )                                               AS raw_outputs
    ))) AS raw_tov_markup,

    Just(Yson::From(AsStruct(
        COALESCE(CAST(f.for_join AS String), '')        AS task_id,
        $yson_null                                      AS pool_id,
        $yson_null                                      AS project_id,
        -- воркеров по-прежнему два: доп. джадж по речевым не размечает пару
        -- целиком, его ответ лежит отдельно в speech_check_A/B
        AsList('direct', 'reverse')                     AS worker_ids,

        COALESCE(CAST(f.answer_1 AS String), '')        AS answer_A,
        COALESCE(CAST(f.answer_2 AS String), '')        AS answer_B,
        COALESCE(CAST(f.answer_source_1 AS String), '') AS source_A,
        COALESCE(CAST(f.answer_source_2 AS String), '') AS source_B,

        -- сводные чекбоксы: маркер стоит, если его увидел хотя бы один проход,
        -- а речевые — ещё и если их нашёл доп. джадж
        $markers_to_checkboxes(f.mk1_dir, f.mk1_rev, f.speech_extra_A) AS checkboxes_A,
        $markers_to_checkboxes(f.mk2_dir, f.mk2_rev, f.speech_extra_B) AS checkboxes_B,

        $clc(f.dir_yson, f.rev_yson, 'model_1_evaluation', 'model_2_evaluation') AS pointwise_A,
        $clc(f.dir_yson, f.rev_yson, 'model_2_evaluation', 'model_1_evaluation') AS pointwise_B,

        $marker_list(f.mk1_dir, f.mk1_rev, f.speech_extra_A) AS markers_A,
        $marker_list(f.mk2_dir, f.mk2_rev, f.speech_extra_B) AS markers_B,

        -- откуда взялись речевые: если их поставил только доп. джадж,
        -- reasoning так и говорит
        $speech_block(f.mk1_dir, f.mk1_rev, f.speech_extra_A, f.speech_extra_A_why) AS speech_check_A,
        $speech_block(f.mk2_dir, f.mk2_rev, f.speech_extra_B, f.speech_extra_B_why) AS speech_check_B,

        AsList(AsList(), AsList())                      AS annotations,
        -- список позиционный, по элементу на воркера из worker_ids. Черновик
        -- у обоих проходов общий, поэтому вместо копии во второй позиции —
        -- лингвистический скан: разные куски разбора вместо одного дважды
        AsList(
            COALESCE(CAST(f.model_1_analysis AS String), ''),
            COALESCE(CAST(f.model_1_linguistic_scan AS String), '')
        )                                               AS comments_A,
        AsList(
            COALESCE(CAST(f.model_2_analysis AS String), ''),
            COALESCE(CAST(f.model_2_linguistic_scan AS String), '')
        )                                               AS comments_B,
        AsList($sbs_why(f.dir_yson), $sbs_why(f.rev_yson)) AS general_comments,

        $yson_null                                      AS task_summarization,

        false                                           AS diff_pa,
        $winner_source(f.tov_winner, f.answer_source_1, f.answer_source_2) AS diff_pa_winner,
        $agreement(f.w_direct, f.w_reversed_norm)       AS diff_pa_winner_agreement,
        $strength(f.w_direct, f.w_reversed_norm)        AS diff_pa_winner_strength,

        false                                           AS direct_speech_A,
        false                                           AS direct_speech_B,

        $winner_source(f.tov_winner, f.answer_source_1, f.answer_source_2) AS winner,
        $agreement(f.w_direct, f.w_reversed_norm)       AS winner_agreement,
        $strength(f.w_direct, f.w_reversed_norm)        AS winner_strength,

        false                                           AS skip
    ))) AS agg_tov_markup

FROM $final AS f;

-- ========================= ВЫХОД 3: исходник + разбор =========================
-- Одна строка = одна пара: слева поля исходника как они лежат в $input3,
-- справа две колонки разбора.
--   raw_tov — сырьё, четыре ключа: common, direct, reverse, speech_judge;
--   out_tov — итог: четыре числа на ответ, флаги маркеров, победитель.
--
-- Раскладка внутри raw_tov: в блоке прохода лежит ответ джаджа как есть,
-- разложенный по ответам, — review_A и review_B это summary, маркеры и
-- звёзды прямо из dst, со всеми обоснованиями. Отдельно из sbs_comparison
-- вынут победитель: сразу сорсом, а не «model_1», и его обоснование рядом.
-- В common то, что относится к паре целиком: маркеры и разбор первого
-- этапа и сведённые по двум проходам звёзды. speech_judge — доп. джадж по
-- речевым, как он ответил, до объединения с проходами.
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
    Just(Yson::From(AsStruct(
        AsStruct(
            -- маркеры первого этапа, колонкой как есть
            f.markers_1_answer AS markers_A,
            f.markers_2_answer AS markers_B,

            -- разбор первого этапа: у проходов он общий
            COALESCE(CAST(f.model_1_analysis AS String), '')        AS analysis_A,
            COALESCE(CAST(f.model_2_analysis AS String), '')        AS analysis_B,
            COALESCE(CAST(f.model_1_linguistic_scan AS String), '') AS linguistic_scan_A,
            COALESCE(CAST(f.model_2_linguistic_scan AS String), '') AS linguistic_scan_B,

            -- звёзды колонкой как есть, ничего не пересчитываем
            f.pointwise_1 AS pointwise_A,
            f.pointwise_2 AS pointwise_B
        ) AS common,
        AsStruct(
            $winner_source(f.w_direct, f.answer_source_1, f.answer_source_2) AS winner,
            $sbs_why(f.dir_yson)                                             AS winner_reasoning,
            $review(f.dir_yson, 'model_1_markers_review', 'model_1_evaluation') AS review_A,
            $review(f.dir_yson, 'model_2_markers_review', 'model_2_evaluation') AS review_B
        ) AS direct,
        -- в обратном проходе ответы переставлены: answer_1 лежит под model_2.
        -- Раскладываем по A и B, а не по model_N, иначе блоки нельзя ставить
        -- рядом. Победитель по той же причине уже развёрнут
        AsStruct(
            $winner_source(f.w_reversed_norm, f.answer_source_1, f.answer_source_2) AS winner,
            $sbs_why(f.rev_yson)                                             AS winner_reasoning,
            $review(f.rev_yson, 'model_2_markers_review', 'model_2_evaluation') AS review_A,
            $review(f.rev_yson, 'model_1_markers_review', 'model_1_evaluation') AS review_B
        ) AS reverse,
        -- доп. джадж по речевым: только то, что сказал он сам. Объединение
        -- с проходами лежит ниже, в out_tov
        AsStruct(
            f.speech_extra_A      AS language_errors_A,
            f.speech_extra_B      AS language_errors_B,
            f.speech_extra_A_why  AS language_errors_A_reasoning,
            f.speech_extra_B_why  AS language_errors_B_reasoning,
            f.speech_extra_A_scan AS scan_A,
            f.speech_extra_B_scan AS scan_B
        ) AS speech_judge
    ))) AS raw_tov,

    -- ---------- итог ----------
    Just(Yson::From(AsStruct(
        COALESCE(CAST(f.answer_source_1 AS String), '') AS source_A,
        COALESCE(CAST(f.answer_source_2 AS String), '') AS source_B,

        -- четыре конечных числа на ответ, без обвязки
        $clc_struct(f.dir_yson, f.rev_yson, 'model_1_evaluation', 'model_2_evaluation') AS pointwise_A,
        $clc_struct(f.dir_yson, f.rev_yson, 'model_2_evaluation', 'model_1_evaluation') AS pointwise_B,

        -- словарь флагов: имя маркера -> bool, ничего кроме.
        -- language_errors здесь уже с добором доп. джаджа
        $flags_dict(f.mk1_dir, f.mk1_rev, f.speech_extra_A) AS markers_A,
        $flags_dict(f.mk2_dir, f.mk2_rev, f.speech_extra_B) AS markers_B,

        -- почему у речевых стоит true: проходы, доп. джадж или оба
        $speech_block(f.mk1_dir, f.mk1_rev, f.speech_extra_A, f.speech_extra_A_why) AS speech_check_A,
        $speech_block(f.mk2_dir, f.mk2_rev, f.speech_extra_B, f.speech_extra_B_why) AS speech_check_B,

        $winner_source(f.tov_winner, f.answer_source_1, f.answer_source_2) AS winner,

        -- согласованность проходов: по ней и отбирают строки на ручной просмотр
        $agreement(f.w_direct, f.w_reversed_norm) AS winner_agreement,
        $strength(f.w_direct, f.w_reversed_norm)  AS winner_strength
    ))) AS out_tov

FROM $final AS f
LEFT JOIN $input3 AS i3
ON f.for_join == i3.for_join;
