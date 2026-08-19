PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;
DECLARE $output1 AS String;

-- Ищем упоминания памяти в reasoning'ах маркеров судьи.
-- Вход: колонка raw_tov с JSON вида
--   { "direct": { "review_A": { "markers": { "<маркер>": { "reasoning": "...", "score": N } }, ... },
--                 "review_B": { ... }, "winner": ..., "winner_reasoning": ... },
--     "reverse": { ... },
--     "speech_judge": { ... } }
-- Блоки проходов ищутся по наличию review_A / review_B, поэтому запрос переживёт
-- и один проход, и другие имена ключей верхнего уровня.
--
-- Выход (по 3 колонки на ответ):
--   has_memory_A / has_memory_B          — Bool: память упомянута хоть в одном reasoning
--   memory_markers_A / memory_markers_B  — List<String>: маркеры, где она упомянута
--   memory_markers_A_str / ..._B_str     — те же списки строкой, чтобы читалось в UI
-- Если проходов больше одного, имя маркера идёт с префиксом прохода: "reverse.liveliness".

$script = @@#py
import json
import re
from yql.typing import *


# Что считаем упоминанием памяти. Список правится в одну строку.
_MEMORY_PARTS = [
    r'памят[ьиею]\w*',                                    # память, памяти, памятью (не «памятка»/«памятник»)
    r'запомн\w*', r'запомин\w*',                          # запомнил, запоминание
    r'вспомн\w*', r'вспомин\w*',                          # вспомнил, вспоминает
    r'припомн\w*', r'припомин\w*',
    r'(?<![а-яё])помн\w*',                                # помнит, помню (но не «напомнить»)
    r'memory', r'remember',
    # r'забы\w*',                                         # включи, если «забыл/забывает» тоже считать памятью
]
_MEMORY_RE = re.compile('(?iu)(' + '|'.join(_MEMORY_PARTS) + ')')

_REVIEW_KEYS = ('review_A', 'review_B', 'review_a', 'review_b')


def _parse(raw):
    """Строка -> dict. Переживает ```json-обёртку и мусор по краям."""
    if raw is None:
        return None
    s = raw.decode('utf-8', 'ignore') if isinstance(raw, bytes) else str(raw)

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
        return json.loads(s, strict=False)
    except Exception:
        return None


def _strings(node, acc):
    """Все строки внутри значения маркера: reasoning, comment, что угодно вложенное."""
    if isinstance(node, str):
        acc.append(node)
    elif isinstance(node, dict):
        for v in node.values():
            _strings(v, acc)
    elif isinstance(node, list):
        for v in node:
            _strings(v, acc)
    return acc


def _hits(review):
    """Имена маркеров одного review, в reasoning которых есть память."""
    if not isinstance(review, dict):
        return []
    markers = review.get('markers')
    if not isinstance(markers, dict):
        return []
    return [
        str(name)
        for name, value in markers.items()
        if any(_MEMORY_RE.search(t) for t in _strings(value, []))
    ]


def _passes(data):
    """[(имя прохода, блок с review_A/review_B)] — direct, reverse и т.п."""
    found = []

    def walk(node, key):
        if isinstance(node, list):
            for item in node:
                walk(item, key)
            return
        if not isinstance(node, dict):
            return
        if any(k in node for k in _REVIEW_KEYS):
            found.append((key, node))
            return
        for k, v in node.items():
            walk(v, k)

    walk(data, '')
    return found


def memory_scan(raw: Optional[Utf8]) -> Optional[Utf8]:
    """raw_tov -> {"A": {"has": bool, "markers": [...]}, "B": {...}}"""
    result = {'A': {'has': False, 'markers': []},
              'B': {'has': False, 'markers': []}}

    data = _parse(raw)
    if data is None:
        return json.dumps(result, ensure_ascii=False)

    passes = _passes(data)
    multi = len(passes) > 1

    for side in ('A', 'B'):
        names, seen = [], set()
        for pass_name, block in passes:
            review = block.get('review_' + side)
            if review is None:
                review = block.get('review_' + side.lower())
            prefix = (str(pass_name) + '.') if (multi and pass_name) else ''
            for name in _hits(review):
                full = prefix + name
                if full not in seen:
                    seen.add(full)
                    names.append(full)
        result[side] = {'has': bool(names), 'markers': names}

    return json.dumps(result, ensure_ascii=False)
@@;

$memory_scan = Python3::memory_scan($script);

$has     = ($mem, $side) -> { RETURN Yson::ConvertToBool(Yson::Lookup(Yson::Lookup($mem, $side), 'has')) ?? false; };
$markers = ($mem, $side) -> {
    RETURN COALESCE(
        Yson::ConvertToStringList(Yson::Lookup(Yson::Lookup($mem, $side), 'markers')),
        ListCreate(String)
    );
};

$scanned = (
    SELECT
        t.*,
        -- если raw_tov хранится как Yson/Json, замени на:
        -- CAST(Yson::SerializeJson(Yson::From(t.raw_tov)) AS Utf8)
        Yson::ParseJson($memory_scan(CAST(t.raw_tov AS Utf8))) AS mem
    FROM $input1 AS t
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    $has(s.mem, 'A')                                     AS has_memory_A,
    $markers(s.mem, 'A')                                 AS memory_markers_A,
    String::JoinFromList($markers(s.mem, 'A'), ', ')     AS memory_markers_A_str,

    $has(s.mem, 'B')                                     AS has_memory_B,
    $markers(s.mem, 'B')                                 AS memory_markers_B,
    String::JoinFromList($markers(s.mem, 'B'), ', ')     AS memory_markers_B_str,

    s.*
    WITHOUT IF EXISTS s.mem
FROM $scanned AS s;
