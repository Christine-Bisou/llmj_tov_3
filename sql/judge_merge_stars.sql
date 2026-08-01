PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

-- input1 — прямой прогон маркеров, input2 — обратный, input3 — прогон звёзд.
--
-- Третья таблица приходит из другого блока графа и лежит в другой раскладке:
-- на верхнем уровне у неё только answers, input_final_messages, input_meta,
-- input_render_data. Ни instruct_id, ни dst там нет — instruct_id спрятан
-- внутри Yson-колонки input_meta, ответ модели лежит в answers. Поэтому
-- третий вход приводится к виду (instruct_id, stars_yson) в $stars ниже,
-- и только потом джойнится.

$yson_null = Just(Yson::From({}));

$script = @@#py
import json
import cyson
def process_json(s):
    """
    (Utf8?) -> Yson?
    """
    if s is None:
        return None

    if s.startswith('```json'):
        s = s.removeprefix('```json')
    elif s.startswith('```'):
        s = s.removeprefix('```')
    if s.endswith('```'):
        s = s.removesuffix('```')
    try:
        j = json.loads(s, strict=False)
        return cyson.dumps(j)
    except Exception as e:
        return None
@@;

$process_json = Python3::process_json($script);

-- Разбор колонки answers из третьего входа. На вход подаётся её JSON-сериализация,
-- потому что answers бывает и одной строкой, и списком ответов, и списком объектов
-- с текстом внутри — спускаемся до первой строки, какой бы из трёх форм ни пришло.
$stars_script = @@#py
import json
import cyson


def extract_stars(s):
    """
    (String?) -> Yson?
    """
    if s is None:
        return None
    if isinstance(s, bytes):
        s = s.decode('utf-8', errors='ignore')

    try:
        val = json.loads(s)
    except Exception:
        val = s

    # разворачиваем обёртки: [ ... ], [{'text': ...}], {'answer': ...}
    for _ in range(8):
        if isinstance(val, (list, tuple)):
            if not val:
                return None
            val = val[0]
            continue
        if isinstance(val, dict):
            for k in ('text', 'answer', 'response', 'content', 'dst'):
                if k in val:
                    val = val[k]
                    break
            else:
                # звёзды уже пришли разобранным объектом
                return cyson.dumps(val)
            continue
        break

    if not isinstance(val, str):
        return None

    val = val.strip()
    if val.startswith('```json'):
        val = val[7:]
    elif val.startswith('```'):
        val = val[3:]
    if val.endswith('```'):
        val = val[:-3]
    val = val.strip()

    i, j = val.find('{'), val.rfind('}')
    if i != -1 and j != -1 and j > i:
        val = val[i:j + 1]

    try:
        return cyson.dumps(json.loads(val, strict=False))
    except Exception:
        return None
@@;

$extract_stars = Python3::extract_stars($stars_script);

-- instruct_id из input_meta. ConvertToString вернёт null, если ключ пришёл числом,
-- поэтому вторым шагом пробуем Int64 (yson.DisableStrict гасит ошибку конверсии).
$meta_instruct_id = ($m) -> {
    RETURN COALESCE(
        Yson::ConvertToString(Yson::Lookup($m, 'instruct_id')),
        CAST(Yson::ConvertToInt64(Yson::Lookup($m, 'instruct_id')) AS String)
    );
};

$get_markers = ($yson_array) -> {
    RETURN ListMap(
        Yson::ConvertToList($yson_array),
        ($item) -> { RETURN Yson::ConvertToString($item.marker_id); }
    );
};

$has_marker = ($markers, $marker_id) -> {
    RETURN ListLength(ListFilter(
        $markers,
        ($m) -> { RETURN $m IS NOT NULL AND $m = $marker_id; }
    )) > 0u;
};

$markers_to_checkboxes = ($markers) -> {
    RETURN Just(Yson::From(ToDict(AsList(
        AsTuple("point_bad_intro",              Just(Yson::From($has_marker($markers, "bad_intro")))),
        AsTuple("point_bad_proactivity",        Just(Yson::From($has_marker($markers, "bad_proactivity")))),
        AsTuple("tov_minus_addressing",         Just(Yson::From(false))),
        AsTuple("tov_minus_boundary_violation", Just(Yson::From($has_marker($markers, "boundaries_violation")))),
        AsTuple("tov_minus_cliches",            Just(Yson::From($has_marker($markers, "template_phrases")))),
        AsTuple("tov_minus_dry",                Just(Yson::From($has_marker($markers, "stuffy_bureaucratic")))),
        AsTuple("tov_minus_language_errors",    Just(Yson::From($has_marker($markers, "language_errors")))),
        AsTuple("tov_minus_overemotional",      Just(Yson::From($has_marker($markers, "over_emotional")))),
        AsTuple("tov_plus_clarity",             Just(Yson::From($has_marker($markers, "clarity")))),
        AsTuple("tov_plus_empathy",             Just(Yson::From($has_marker($markers, "empathy")))),
        AsTuple("tov_plus_humor",               Just(Yson::From($has_marker($markers, "humor_metaphors")))),
        AsTuple("tov_plus_subject",             Just(Yson::From($has_marker($markers, "subjectivity")))),
        AsTuple("tov_plus_tone_match",          Just(Yson::From($has_marker($markers, "tone_match")))),
        AsTuple("tov_tone_unacceptable",        Just(Yson::From($has_marker($markers, "critical_tone"))))
    ))));
};

-- ========================= POINTWISE =========================
-- Оценка аспекта одним проходом. Без `?? 0.0`: пропуск должен остаться null,
-- иначе в разметку уедет выдуманный ноль.
$score = ($node, $model, $asp) -> {
    RETURN Yson::ConvertToDouble(
        Yson::Lookup(Yson::Lookup(Yson::Lookup($node, $model), $asp), 'score')
    );
};

$score_int = ($node, $model, $asp) -> {
    RETURN CAST(Math::Floor($score($node, $model, $asp)) AS Int64);
};

-- Четыре звезды одного ответа. Звёзды приходят одним прогоном (input3),
-- усреднять нечего — поэтому одна функция и на raw_outputs, и на agg.
$pointwise = ($node, $model) -> {
    RETURN Just(Yson::From(ToDict(AsList(
        AsTuple("clarity",    $score_int($node, $model, 'clarity')),
        AsTuple("liveliness", $score_int($node, $model, 'liveliness')),
        AsTuple("connect",    $score_int($node, $model, 'connect')),
        AsTuple("overall",    $score_int($node, $model, 'overall'))
    ))));
};

-- Третий вход в пригодном для JOIN виде: ключ поднят из input_meta наверх,
-- ответ модели разобран из answers.
$stars = (
    SELECT
        $meta_instruct_id(input_meta)                                AS instruct_id,
        $extract_stars(CAST(Yson::SerializeJson(answers) AS String))  AS stars_yson
    FROM {{input3}}
);

$parsed = (
    SELECT
        d.*,
        Yson::LookupString(dst_yson_direct, 'model_winner')??'draw' as model_winner_direct,
        Yson::LookupString(dst_yson_reversed, 'model_winner')??'draw' as model_winner_reversed,
        CASE
            WHEN Yson::LookupString(dst_yson_reversed, 'model_winner')??'draw' = 'model_1' THEN 'model_2'
            WHEN Yson::LookupString(dst_yson_reversed, 'model_winner')??'draw' = 'model_2' THEN 'model_1'
            ELSE 'draw'
        END AS model_winner_reversed_normalized,

        ListUniq(ListExtend(
            $get_markers(dst_yson_direct.model_1_markers),
            $get_markers(dst_yson_reversed.model_2_markers)
        )) AS model_1_markers,

        ListUniq(ListExtend(
            $get_markers(dst_yson_direct.model_2_markers),
            $get_markers(dst_yson_reversed.model_1_markers)
        )) AS model_2_markers,

        Just(Yson::From(
            <|
                direct_model_1_markers: $get_markers(dst_yson_direct.model_1_markers),
                direct_model_2_markers: $get_markers(dst_yson_direct.model_2_markers),
                reversed_model_1_markers: $get_markers(dst_yson_reversed.model_1_markers),
                reversed_model_2_markers: $get_markers(dst_yson_reversed.model_2_markers),
                model_winner_direct: Yson::LookupString(dst_yson_direct, 'model_winner')??'draw' ,
                model_winner_reversed: Yson::LookupString(dst_yson_reversed, 'model_winner')??'draw',
                model_winner_reversed_normalized: CASE WHEN Yson::LookupString(dst_yson_reversed, 'model_winner')??'draw' = 'model_1' THEN 'model_2' WHEN Yson::LookupString(dst_yson_reversed, 'model_winner')??'draw' = 'model_2' THEN 'model_1' ELSE 'draw' END,
                reasoning_direct: Yson::LookupString(dst_yson_direct, 'reasoning')??'' ,
                reasoning_reversed: Yson::LookupString(dst_yson_reversed, 'reasoning')??'',
                stars_found: stars_yson IS NOT NULL,
                process_url: 'https://nirvana.yandex-team.ru/process/3eef135a-2d28-4131-a06e-382307db3017',
                graph_owner: 'lomalovo'
            |>
        )) as meta_info,
        WITHOUT IF EXISTS d.meta_info

    FROM (
        SELECT
            i1.*,
            $process_json(CAST(i1.dst AS UTF8?)) as dst_yson_direct,
            $process_json(CAST(i2.dst AS UTF8?)) as dst_yson_reversed,
            i3.stars_yson                        as stars_yson,
            WITHOUT IF EXISTS i1.dst_yson_direct, i1.dst_yson_reversed, i1.stars_yson
        -- Соединяются три таблицы, а в multi-way JOIN YQL требует ON:
        -- USING разрешён только когда таблиц ровно две.
        FROM {{input1}} as i1
        INNER JOIN {{input2}} as i2
        ON i1.instruct_id = i2.instruct_id
        -- LEFT, а не INNER: пара без звёзд должна доехать с пустым pointwise,
        -- а не исчезнуть из разметки молча.
        -- Ключ $stars собран из Yson, его тип может не совпасть с типом
        -- instruct_id в первой таблице — сравниваем строками явно.
        LEFT JOIN $stars as i3
        ON CAST(i1.instruct_id AS String) = i3.instruct_id
    ) as d
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
            ELSE "draw"
        END AS tov_winner
    FROM $parsed as p
);

$final_data = (
    SELECT
        -- Те же колонки, что и во второй версии склейки: их читают маршрутизация
        -- на третий проход и метрики. Звёзды здесь прогоняются один раз, без
        -- перестановки, поэтому «среднее» — это просто выставленная оценка.
        $score(wc.stars_yson, 'model_1_evaluation', 'overall') AS m1_overall_avg,
        $score(wc.stars_yson, 'model_2_evaluation', 'overall') AS m2_overall_avg,

        wc.*,
        WITHOUT IF EXISTS
            wc.dst, wc.dst_yson, wc.dst_yson_direct, wc.dst_yson_reversed, wc.stars_yson,
            wc.infer_dialog, wc.tov_prompt,
            wc.model_winner_direct, wc.model_winner_reversed, wc.model_winner_reversed_normalized
    FROM $winner_calc as wc
);

$get_winner_source = ($winner, $src1, $src2) -> {
    RETURN CASE $winner
        WHEN 'model_1' THEN COALESCE(CAST($src1 AS String), "")
        WHEN 'model_2' THEN COALESCE(CAST($src2 AS String), "")
        ELSE "draw"
    END;
};

INSERT INTO {{output1}} WITH TRUNCATE
SELECT * FROM $final_data;

INSERT INTO {{output2}} WITH TRUNCATE
SELECT
    wc.instruct_id AS instruct_id,
    Just(Yson::From(ToDict(AsList(
        AsTuple("task_id",      Just(Yson::From(COALESCE(CAST(wc.instruct_id AS String), "")))),
        AsTuple("pool_id",      $yson_null),
        AsTuple("project_id",   $yson_null),
        AsTuple("answer_A",     Just(Yson::From(COALESCE(CAST(wc.answer_1 AS String), "")))),
        AsTuple("answer_B",     Just(Yson::From(COALESCE(CAST(wc.answer_2 AS String), "")))),
        AsTuple("source_A",     Just(Yson::From(COALESCE(CAST(wc.answer_source_1 AS String), "")))),
        AsTuple("source_B",     Just(Yson::From(COALESCE(CAST(wc.answer_source_2 AS String), "")))),
        AsTuple("checkboxes",   Just(Yson::From(ToDict(AsList())))),
        AsTuple("markers",      Just(Yson::From(AsList()))),

        AsTuple("raw_outputs", Just(Yson::From(AsList(
            Just(Yson::From(ToDict(AsList(
                AsTuple("worker_id",        Just(Yson::From("direct"))),
                AsTuple("assignment_id",    $yson_null),
                AsTuple("assignment_link",  $yson_null),
                AsTuple("annotations",      Just(Yson::From(AsList()))),
                AsTuple("checkboxes_A",     $markers_to_checkboxes($get_markers(wc.dst_yson_direct.model_1_markers))),
                AsTuple("checkboxes_B",     $markers_to_checkboxes($get_markers(wc.dst_yson_direct.model_2_markers))),
                AsTuple("pointwise_A",      $pointwise(wc.stars_yson, 'model_1_evaluation')),
                AsTuple("pointwise_B",      $pointwise(wc.stars_yson, 'model_2_evaluation')),
                AsTuple("comment_A",        $yson_null),
                AsTuple("comment_B",        $yson_null),
                AsTuple("general_comment",  Just(Yson::From(COALESCE(Yson::LookupString(wc.meta_info, "reasoning_direct"), "")))),
                AsTuple("comment_judge",    $yson_null),
                AsTuple("diff_pa",          $yson_null),
                AsTuple("diff_pa_winner",   Just(Yson::From($get_winner_source(wc.model_winner_direct, wc.answer_source_1, wc.answer_source_2)))),
                AsTuple("direct_speech_A",  $yson_null),
                AsTuple("direct_speech_B",  $yson_null),
                AsTuple("markup_dt",        $yson_null),
                AsTuple("skip",             $yson_null),
                AsTuple("winner",           Just(Yson::From($get_winner_source(wc.model_winner_direct, wc.answer_source_1, wc.answer_source_2))))
            )))),

            Just(Yson::From(ToDict(AsList(
                AsTuple("worker_id",        Just(Yson::From("reverse"))),
                AsTuple("assignment_id",    $yson_null),
                AsTuple("assignment_link",  $yson_null),
                AsTuple("annotations",      Just(Yson::From(AsList()))),
                AsTuple("checkboxes_A",     $markers_to_checkboxes($get_markers(wc.dst_yson_reversed.model_1_markers))),
                AsTuple("checkboxes_B",     $markers_to_checkboxes($get_markers(wc.dst_yson_reversed.model_2_markers))),
                -- звёзды прогонялись один раз, в прямой ориентации: перестановки
                -- здесь нет, и цифры те же, что у worker'а direct
                AsTuple("pointwise_A",      $pointwise(wc.stars_yson, 'model_1_evaluation')),
                AsTuple("pointwise_B",      $pointwise(wc.stars_yson, 'model_2_evaluation')),
                AsTuple("comment_A",        $yson_null),
                AsTuple("comment_B",        $yson_null),
                AsTuple("general_comment",  Just(Yson::From(COALESCE(Yson::LookupString(wc.meta_info, "reasoning_reversed"), "")))),
                AsTuple("comment_judge",    $yson_null),
                AsTuple("diff_pa",          $yson_null),
                AsTuple("diff_pa_winner",   Just(Yson::From($get_winner_source(wc.model_winner_reversed_normalized, wc.answer_source_1, wc.answer_source_2)))),
                AsTuple("direct_speech_A",  $yson_null),
                AsTuple("direct_speech_B",  $yson_null),
                AsTuple("markup_dt",        $yson_null),
                AsTuple("skip",             $yson_null),
                AsTuple("winner",           Just(Yson::From($get_winner_source(wc.model_winner_reversed_normalized, wc.answer_source_1, wc.answer_source_2))))
            ))))
        ))))
    )))) AS raw_tov_markup,

    Just(Yson::From(ToDict(AsList(
        AsTuple("task_id",                  Just(Yson::From(COALESCE(CAST(wc.instruct_id AS String), "")))),
        AsTuple("pool_id",                  $yson_null),
        AsTuple("project_id",               $yson_null),
        AsTuple("worker_ids",               Just(Yson::From(AsList("direct", "reverse")))),

        AsTuple("answer_A",                 Just(Yson::From(COALESCE(CAST(wc.answer_1 AS String), "")))),
        AsTuple("answer_B",                 Just(Yson::From(COALESCE(CAST(wc.answer_2 AS String), "")))),
        AsTuple("source_A",                 Just(Yson::From(COALESCE(CAST(wc.answer_source_1 AS String), "")))),
        AsTuple("source_B",                 Just(Yson::From(COALESCE(CAST(wc.answer_source_2 AS String), "")))),

        AsTuple("checkboxes_A",             $markers_to_checkboxes(wc.model_1_markers)),
        AsTuple("checkboxes_B",             $markers_to_checkboxes(wc.model_2_markers)),

        AsTuple("pointwise_A",              $pointwise(wc.stars_yson, 'model_1_evaluation')),
        AsTuple("pointwise_B",              $pointwise(wc.stars_yson, 'model_2_evaluation')),

        AsTuple("annotations",              Just(Yson::From(AsList(AsList(), AsList())))),
        AsTuple("comments_A",               Just(Yson::From(AsList("", "")))),
        AsTuple("comments_B",               Just(Yson::From(AsList("", "")))),
        AsTuple("general_comments",         Just(Yson::From(AsList(
            COALESCE(Yson::LookupString(wc.meta_info, "reasoning_direct"),   ""),
            COALESCE(Yson::LookupString(wc.meta_info, "reasoning_reversed"), "")
        )))),

        AsTuple("task_summarization",       $yson_null),

        AsTuple("diff_pa",                  Just(Yson::From(false))),
        AsTuple("diff_pa_winner",           Just(Yson::From($get_winner_source(wc.tov_winner, wc.answer_source_1, wc.answer_source_2)))),
        AsTuple("diff_pa_winner_agreement", Just(Yson::From(IF(wc.model_winner_direct = wc.model_winner_reversed_normalized, 1.0, 0.0)))),
        AsTuple("diff_pa_winner_strength",  Just(Yson::From(IF(wc.model_winner_direct = wc.model_winner_reversed_normalized, "strong", "weak")))),

        AsTuple("direct_speech_A",          Just(Yson::From(false))),
        AsTuple("direct_speech_B",          Just(Yson::From(false))),

        AsTuple("winner",                   Just(Yson::From($get_winner_source(wc.tov_winner, wc.answer_source_1, wc.answer_source_2)))),
        AsTuple("winner_agreement",         Just(Yson::From(IF(wc.model_winner_direct = wc.model_winner_reversed_normalized, 1.0, 0.0)))),
        AsTuple("winner_strength",          Just(Yson::From(IF(wc.model_winner_direct = wc.model_winner_reversed_normalized, "strong", "weak")))),

        AsTuple("skip",                     Just(Yson::From(false)))
    )))) AS agg_tov_markup

FROM $winner_calc AS wc;
