DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;

PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

-- Разбор поинтвайзной разметки.
-- $input1 — результат инфера по первому ответу пары (в промт уходил answer_1),
-- $input2 — по второму. В каждой таблице свой dst с JSON вида
-- {analysis, linguistic_scan, markers, evaluation}.
-- $output1 — одна строка на instruct_id: маркеры и звёзды обоих ответов рядом.
--
-- Если промт был чисто маркерный (без блока звёзд), evaluation в JSON нет:
-- pointwise_* останется пустым, а *_score — нулями.

$script = @@#py
import json
import cyson


MARKER_NAMES = [
    'empathy', 'subjectivity', 'tone_match', 'humor_metaphors', 'critical_tone',
    'bad_intro', 'bad_proactivity', 'over_emotional', 'stuffy_bureaucratic',
    'boundaries_violation', 'template_phrases', 'language_errors', 'inconsistency',
]

ASPECTS = ['clarity', 'liveliness', 'connect', 'overall']


def _to_score(value):
    """Звезда может приехать как 4, 4.0 или "4" — приводим к int, мусор -> 0."""
    if isinstance(value, bool):
        return 0
    try:
        return int(round(float(value)))
    except (TypeError, ValueError):
        return 0


def parse_dst_pointwise(s):
    """
    (String?) -> Yson?
    Нормализует ответ джаджа: все 13 маркеров всегда на месте (отсутствующий
    считается невыставленным), все 4 аспекта всегда на месте.
    """
    if s is None:
        return None

    # Декодируем байты в нормальную строку
    if isinstance(s, bytes):
        s = s.decode('utf-8', errors='ignore')
    else:
        s = str(s)

    # Очищаем от маркдауна
    s = s.strip()
    if s.startswith('```json'):
        s = s[7:]
    elif s.startswith('```'):
        s = s[3:]
    if s.endswith('```'):
        s = s[:-3]
    s = s.strip()

    # Отрезаем всё до первой { и после последней } — модель любит дописать
    # пару слов вокруг JSON
    i, j = s.find('{'), s.rfind('}')
    if i != -1 and j != -1 and j > i:
        s = s[i:j + 1]

    try:
        data = json.loads(s, strict=False)
        if not isinstance(data, dict):
            return None

        raw_markers = data.get('markers') or {}
        if not isinstance(raw_markers, dict):
            raw_markers = {}
        markers = {}
        for name in MARKER_NAMES:
            val = raw_markers.get(name)
            if not isinstance(val, dict):
                val = {}
            markers[name] = {
                'is_present': bool(val.get('is_present', False)),
                'explanation': str(val.get('explanation', '')),
            }

        raw_eval = data.get('evaluation') or {}
        if not isinstance(raw_eval, dict):
            raw_eval = {}
        evaluation = {}
        for asp in ASPECTS:
            val = raw_eval.get(asp)
            if not isinstance(val, dict):
                val = {}
            evaluation[asp] = {
                'score': _to_score(val.get('score')),
                'reasoning': str(val.get('reasoning', '')),
            }

        parsed_data = {
            'analysis': str(data.get('analysis', '')),
            'linguistic_scan': str(data.get('linguistic_scan', '')),
            'markers': markers,
            'evaluation': evaluation,
            # промт без блока звёзд отличаем по отсутствию ключа, а не по нулям
            'has_evaluation': bool(raw_eval),
        }

        return cyson.dumps(parsed_data)
    except Exception:
        # Если JSON всё равно кривой, вернём None (выдаст null)
        return None
@@;

$parse_dst = Python3::parse_dst_pointwise($script);

-- ========================= ДОСТАВАЛКИ =========================
$markers  = ($node) -> { RETURN Yson::Lookup($node, 'markers'); };
$analysis = ($node) -> { RETURN Yson::LookupString($node, 'analysis') ?? ''; };
$scan     = ($node) -> { RETURN Yson::LookupString($node, 'linguistic_scan') ?? ''; };
$eval     = ($node) -> { RETURN Yson::Lookup($node, 'evaluation'); };

-- ConvertToDouble вместо LookupInt64: переживёт и 4, и 4.0, и "4"
$score = ($node, $asp) -> {
    RETURN CAST(
        Yson::ConvertToDouble(
            Yson::Lookup(Yson::Lookup(Yson::Lookup($node, 'evaluation'), $asp), 'score')
        ) ?? 0.0 AS Int64
    );
};

-- clc_metrics в том же виде, в каком его собирает judge_merge_pretty.sql
$clc = ($node) -> {
    RETURN Just(Yson::From(<|
        clarity:    $score($node, 'clarity'),
        liveliness: $score($node, 'liveliness'),
        connect:    $score($node, 'connect'),
        overall:    $score($node, 'overall')
    |>));
};

-- список имён сработавших маркеров — удобно глазами и для группировок
$marker_names = AsList(
    'empathy', 'subjectivity', 'tone_match', 'humor_metaphors', 'critical_tone',
    'bad_intro', 'bad_proactivity', 'over_emotional', 'stuffy_bureaucratic',
    'boundaries_violation', 'template_phrases', 'language_errors', 'inconsistency'
);

$present = ($node) -> {
    RETURN ListFilter($marker_names, ($n) -> {
        RETURN Yson::ConvertToBool(
            Yson::Lookup(Yson::Lookup(Yson::Lookup($node, 'markers'), $n), 'is_present')
        ) ?? false;
    });
};

-- ========================= РАЗБОР =========================
-- Парсим по одному разу на строку: $parse_dst — питон, дёргать его в каждой
-- проекции дорого.
$parsed_1 = (
    SELECT t.*, $parse_dst(CAST(t.dst AS String)) AS node
    FROM $input1 AS t
);

$parsed_2 = (
    SELECT
        p.instruct_id AS instruct_id,
        p.node        AS node
    FROM (
        SELECT t.instruct_id AS instruct_id, $parse_dst(CAST(t.dst AS String)) AS node
        FROM $input2 AS t
    ) AS p
);

-- INNER JOIN: пара без одной из половин дальше не идёт — иначе непарсящийся
-- инфер тихо превратился бы в «все маркеры false и нули по звёздам».
INSERT INTO $output1 WITH TRUNCATE
SELECT
    -- ---------- маркеры ----------
    $markers(a.node)   AS markers_1_answer,
    $markers(b.node)   AS markers_2_answer,
    $markers(a.node)   AS ext_markers_1,   -- имена, которые читает judge_merge_pretty
    $markers(b.node)   AS ext_markers_2,
    $present(a.node)   AS markers_1_list,
    $present(b.node)   AS markers_2_list,

    -- ---------- текстовые части разбора ----------
    $analysis(a.node)  AS model_1_analysis,
    $analysis(b.node)  AS model_2_analysis,
    $scan(a.node)      AS model_1_linguistic_scan,
    $scan(b.node)      AS model_2_linguistic_scan,

    -- ---------- поинтвайз ----------
    $eval(a.node)      AS pointwise_1,      -- score + reasoning по каждому аспекту
    $eval(b.node)      AS pointwise_2,
    $clc(a.node)       AS clc_metrics_1,    -- четыре числа, как в разметке
    $clc(b.node)       AS clc_metrics_2,

    $score(a.node, 'clarity')    AS clarity_1,
    $score(a.node, 'liveliness') AS liveliness_1,
    $score(a.node, 'connect')    AS connect_1,
    $score(a.node, 'overall')    AS overall_1,

    $score(b.node, 'clarity')    AS clarity_2,
    $score(b.node, 'liveliness') AS liveliness_2,
    $score(b.node, 'connect')    AS connect_2,
    $score(b.node, 'overall')    AS overall_2,

    -- ---------- служебное ----------
    (a.node IS NOT NULL AND b.node IS NOT NULL) AS parsed_ok,

    -- WITHOUT обязан быть последним элементом списка
    a.* WITHOUT IF EXISTS
        a.node, a.dst, a.answer_slot, a.infer_dialog, a.tov_prompt, a._other,
        a.reasoning_dst,
        a.markers_1_answer, a.markers_2_answer, a.ext_markers_1, a.ext_markers_2,
        a.markers_1_list, a.markers_2_list,
        a.model_1_analysis, a.model_2_analysis,
        a.model_1_linguistic_scan, a.model_2_linguistic_scan,
        a.pointwise_1, a.pointwise_2, a.clc_metrics_1, a.clc_metrics_2,
        a.clarity_1, a.liveliness_1, a.connect_1, a.overall_1,
        a.clarity_2, a.liveliness_2, a.connect_2, a.overall_2,
        a.parsed_ok
FROM $parsed_1 AS a
INNER JOIN $parsed_2 AS b
USING (instruct_id);
