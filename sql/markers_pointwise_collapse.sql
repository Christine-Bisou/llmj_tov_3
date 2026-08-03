PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

-- Схлопывание поинтвайзного первого этапа.
-- Вход {{input1}} — результат инфера по таблице из markers_pointwise_input.sql:
-- две строки на instruct_id (answer_slot = 1 и 2), сырой ответ джаджа в dst.
-- Выход {{output1}} — снова одна строка на instruct_id, с ext_markers_1 /
-- ext_markers_2 в том же виде, в каком их ждёт judge_merge_pretty.sql:
-- ext_markers_1 всегда относится к answer_1, ext_markers_2 — к answer_2.

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

-- В поинтвайзном промте три ключа верхнего уровня:
-- analysis, linguistic_scan, markers.
$markers  = ($node) -> { RETURN Yson::Lookup($node, 'markers'); };
$scan     = ($node) -> { RETURN Yson::LookupString($node, 'linguistic_scan') ?? ''; };
$analysis = ($node) -> { RETURN Yson::LookupString($node, 'analysis') ?? ''; };

$parsed = (
    SELECT
        r.*,
        $process_json(CAST(r.dst AS String)) AS dst_yson
    FROM {{input1}} AS r
);

-- Строка первого ответа несёт весь исходный набор колонок пары.
$slot_1 = (
    SELECT
        $markers(p.dst_yson)  AS ext_markers_1,
        $scan(p.dst_yson)     AS ext_linguistic_scan_1,
        $analysis(p.dst_yson) AS ext_analysis_1,
        p.dst_yson IS NOT NULL AS markers_parsed_1,
        p.* WITHOUT IF EXISTS
            p.dst_yson, p.dst, p.answer_slot,
            p.infer_dialog, p.tov_prompt, p._other, p.reasoning_dst
    FROM $parsed AS p
    WHERE p.answer_slot = 1
);

-- Из строки второго ответа берём только разметку: остальное там дубль.
$slot_2 = (
    SELECT
        p.instruct_id         AS instruct_id,
        $markers(p.dst_yson)  AS ext_markers_2,
        $scan(p.dst_yson)     AS ext_linguistic_scan_2,
        $analysis(p.dst_yson) AS ext_analysis_2,
        p.dst_yson IS NOT NULL AS markers_parsed_2
    FROM $parsed AS p
    WHERE p.answer_slot = 2
);

-- INNER JOIN: пара без одной из половин дальше не идёт. Если строк на выходе
-- меньше, чем instruct_id на входе, значит часть инферов не доехала —
-- это видно по счётчику, а не тихо превращается в «все маркеры false».
INSERT INTO {{output1}} WITH TRUNCATE
SELECT
    s2.ext_markers_2          AS ext_markers_2,
    s2.ext_linguistic_scan_2  AS ext_linguistic_scan_2,
    s2.ext_analysis_2         AS ext_analysis_2,
    s1.markers_parsed_1 AND s2.markers_parsed_2 AS markers_parsed_ok,
    s1.* WITHOUT s1.markers_parsed_1
FROM $slot_1 AS s1
INNER JOIN $slot_2 AS s2
USING (instruct_id);
