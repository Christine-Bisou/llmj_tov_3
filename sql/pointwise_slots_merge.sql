DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;

PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

-- Склейка двух слотов поточечной оценки: $input1 — разбор answer_1,
-- $input2 — разбор answer_2. Одна строка на пару ответов.
--
-- КЛЮЧ ДЖОЙНА: instruct_id + обе модели. instruct_id — ключ задания, а не пары:
-- одно задание обычно оценивается по нескольким парам, и джойн только по нему
-- сцепляет слот от одной пары со слотом от другой.
--
-- Сорсы в ключ идут не как есть, а нормализованными, потому что джойн по сырым
-- колонкам разваливается на ровном месте:
--   * NULL не равен NULL — строка с пустым сорсом молча пропадает;
--   * типы могут не совпасть (String против Utf8, Yson после InferSchema);
--   * порядок сорсов в правой таблице может отличаться.
-- CAST в String + COALESCE снимают первые два пункта, сортировка пары — третий.
-- Что где лежит по факту — покажет pointwise_slots_join_check.sql.

$script = @@#py
import json
import cyson


MARKER_NAMES = [
    'empathy', 'subjectivity', 'tone_match', 'humor_metaphors', 'critical_tone',
    'bad_intro', 'bad_proactivity', 'over_emotional', 'stuffy_bureaucratic',
    'boundaries_violation', 'template_phrases', 'language_errors', 'inconsistency',
]

ASPECTS = ['clarity', 'liveliness', 'connect', 'overall']


def parse_dst_pointwise(s):
    """
    (String?) -> Yson?
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

    # Отрезаем всё до первой { и после последней }
    i, j = s.find('{'), s.rfind('}')
    if i != -1 and j != -1 and j > i:
        s = s[i:j + 1]

    try:
        data = json.loads(s, strict=False)

        def transform_markers(markers_dict):
            markers_dict = markers_dict or {}
            result = {}
            # идём по фиксированному списку: пропущенный моделью маркер
            # считаем невыставленным, иначе метрики поедут
            for name in MARKER_NAMES:
                val = markers_dict.get(name) or {}
                result[name] = {
                    "is_present": bool(val.get("is_present", False)),
                    "explanation": str(val.get("explanation", "")),
                }
            return result

        def transform_evaluation(eval_dict):
            eval_dict = eval_dict or {}
            result = {}
            for asp in ASPECTS:
                val = eval_dict.get(asp) or {}
                try:
                    # звезда приезжает как 4, 4.0 или "4"
                    score = int(round(float(val.get("score"))))
                except (TypeError, ValueError):
                    score = 0
                result[asp] = {
                    "score": score,
                    "reasoning": str(val.get("reasoning", "")),
                }
            return result

        parsed_data = {
            "analysis": str(data.get("analysis", "")),
            "linguistic_scan": str(data.get("linguistic_scan", "")),
            "markers": transform_markers(data.get("markers")),
            "evaluation": transform_evaluation(data.get("evaluation")),
        }

        return cyson.dumps(parsed_data)
    except Exception:
        # Если JSON всё равно кривой, вернем None (выдаст null)
        return None
@@;

$parse_dst = Python3::parse_dst_pointwise($script);

$score = ($node, $asp) -> {
    RETURN CAST(
        Yson::ConvertToDouble(
            Yson::Lookup(Yson::Lookup(Yson::Lookup($node, 'evaluation'), $asp), 'score')
        ) ?? 0.0 AS Int64
    );
};

-- ========================= КЛЮЧ ПАРЫ =========================
-- Пустой сорс превращаем в '', иначе NULL != NULL и строка выпадает из джойна.
$as_key = ($s) -> {
    RETURN COALESCE(CAST($s AS String), '');
};

-- Пару держим отсортированной: два сорса дают одинаковые src_lo/src_hi
-- независимо от того, в каком порядке они записаны в конкретной таблице.
-- Кто из них answer_1, а кто answer_2, определяет answer_slot, а не эти колонки,
-- так что на разбор ответов сортировка не влияет.
$src_lo = ($a, $b) -> {
    RETURN IF($as_key($a) <= $as_key($b), $as_key($a), $as_key($b));
};

$src_hi = ($a, $b) -> {
    RETURN IF($as_key($a) <= $as_key($b), $as_key($b), $as_key($a));
};

-- ========================= СЛОТЫ =========================
$slot_1 = (
    SELECT
        $src_lo(t.answer_source_1, t.answer_source_2) AS src_lo,
        $src_hi(t.answer_source_1, t.answer_source_2) AS src_hi,
        $parse_dst(CAST(t.dst AS String))             AS node,
        t.* WITHOUT IF EXISTS t.src_lo, t.src_hi, t.node
    FROM $input1 AS t
    WHERE t.answer_slot == 1
);

-- Ключевые колонки обязаны быть в проекции: без них джойну не по чему сходиться.
$slot_2 = (
    SELECT
        t.instruct_id                                 AS instruct_id,
        $src_lo(t.answer_source_1, t.answer_source_2) AS src_lo,
        $src_hi(t.answer_source_1, t.answer_source_2) AS src_hi,
        $parse_dst(CAST(t.dst AS String))             AS node
    FROM $input2 AS t
    WHERE t.answer_slot == 2
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    Yson::Lookup(a.node, 'markers')          AS markers_1_answer,
    Yson::Lookup(b.node, 'markers')          AS markers_2_answer,

    Yson::LookupString(a.node, 'analysis')   AS model_1_analysis,
    Yson::LookupString(b.node, 'analysis')   AS model_2_analysis,
    Yson::LookupString(a.node, 'linguistic_scan') AS model_1_linguistic_scan,
    Yson::LookupString(b.node, 'linguistic_scan') AS model_2_linguistic_scan,

    Yson::Lookup(a.node, 'evaluation')       AS pointwise_1,
    Yson::Lookup(b.node, 'evaluation')       AS pointwise_2,

    $score(a.node, 'clarity')                AS clarity_1,
    $score(a.node, 'liveliness')             AS liveliness_1,
    $score(a.node, 'connect')                AS connect_1,
    $score(a.node, 'overall')                AS overall_1,

    $score(b.node, 'clarity')                AS clarity_2,
    $score(b.node, 'liveliness')             AS liveliness_2,
    $score(b.node, 'connect')                AS connect_2,
    $score(b.node, 'overall')                AS overall_2,

    (a.node IS NOT NULL AND b.node IS NOT NULL) AS parsed_ok,

    -- всё остальное (golden_*, worker_*, chief_*, answer_1/2, dialog...) —
    -- из первой таблицы как есть. WITHOUT обязан быть последним в списке.
    a.* WITHOUT IF EXISTS
        a.node, a.dst, a.reasoning_dst, a.infer_dialog, a.answer_slot, a.sol,
        a.src_lo, a.src_hi
FROM $slot_1 AS a
INNER JOIN $slot_2 AS b
USING (instruct_id, src_lo, src_hi);
