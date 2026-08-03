PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

-- Схлопывание поинтвайзного первого этапа.
-- {{input1}} — результат инфера над $output1 из markers_pointwise_input.sql
--              (в промт уходил answer_1), сырой ответ джаджа в dst;
-- {{input2}} — то же самое для answer_2.
-- Выход {{output1}} — снова одна строка на instruct_id, с ext_markers_1 /
-- ext_markers_2 в том же виде, в каком их ждёт judge_merge_pretty.sql:
-- ext_markers_1 всегда относится к answer_1, ext_markers_2 — к answer_2.
--
-- Если узел инфера кладёт результат не в dst, поменяй имя колонки в $parse.

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

-- В поинтвайзном промте ключи верхнего уровня: analysis, linguistic_scan,
-- markers. У объединённого промта (маркеры + звёзды) добавляется evaluation
-- с clarity / liveliness / connect / overall. Если промт был чисто маркерный,
-- Lookup вернёт null и колонка просто останется пустой.
$markers    = ($node) -> { RETURN Yson::Lookup($node, 'markers'); };
$scan       = ($node) -> { RETURN Yson::LookupString($node, 'linguistic_scan') ?? ''; };
$analysis   = ($node) -> { RETURN Yson::LookupString($node, 'analysis') ?? ''; };
$evaluation = ($node) -> { RETURN Yson::Lookup($node, 'evaluation'); };

-- Первая таблица несёт весь исходный набор колонок пары — она и станет базой.
$slot_1 = (
    SELECT
        $markers(node)    AS ext_markers_1,
        $evaluation(node) AS ext_evaluation_1,
        $scan(node)       AS ext_linguistic_scan_1,
        $analysis(node)   AS ext_analysis_1,
        node IS NOT NULL AS markers_parsed_1,
        p.* WITHOUT IF EXISTS
            p.node, p.dst, p.answer_slot,
            p.infer_dialog, p.tov_prompt, p._other, p.reasoning_dst
    FROM (
        SELECT r.*, $process_json(CAST(r.dst AS String)) AS node
        FROM {{input1}} AS r
    ) AS p
);

-- Из второй берём только разметку: остальные колонки там те же самые.
$slot_2 = (
    SELECT
        p.instruct_id    AS instruct_id,
        $markers(node)    AS ext_markers_2,
        $evaluation(node) AS ext_evaluation_2,
        $scan(node)       AS ext_linguistic_scan_2,
        $analysis(node)   AS ext_analysis_2,
        node IS NOT NULL AS markers_parsed_2
    FROM (
        SELECT r.*, $process_json(CAST(r.dst AS String)) AS node
        FROM {{input2}} AS r
    ) AS p
);

-- INNER JOIN: пара без одной из половин дальше не идёт. Если строк на выходе
-- меньше, чем на входе, значит часть инферов не доехала — это видно по
-- счётчику, а не тихо превращается в «все маркеры false».
INSERT INTO {{output1}} WITH TRUNCATE
SELECT
    s2.ext_markers_2          AS ext_markers_2,
    s2.ext_evaluation_2       AS ext_evaluation_2,
    s2.ext_linguistic_scan_2  AS ext_linguistic_scan_2,
    s2.ext_analysis_2         AS ext_analysis_2,
    s1.markers_parsed_1 AND s2.markers_parsed_2 AS markers_parsed_ok,
    s1.* WITHOUT s1.markers_parsed_1
FROM $slot_1 AS s1
INNER JOIN $slot_2 AS s2
USING (instruct_id);
