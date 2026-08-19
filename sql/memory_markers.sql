PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;

-- Ищем упоминания памяти в reasoning'ах маркеров судьи.
-- input1 — основная таблица, ключ в колонке instruct_id. Все её колонки
--          доезжают до выхода как есть.
-- input2 — таблица с raw_tov, ключ в input_meta.instruct_id.
-- Вход: колонка raw_tov с JSON вида
--   { "direct": { "review_A": { "markers": { "<маркер>": { "reasoning": "...", "score": N } }, ... },
--                 "review_B": { ... }, "winner": ..., "winner_reasoning": ... },
--     "reverse": { ... },
--     "speech_judge": { ... } }
-- Блоки проходов ищутся по наличию review_A / review_B, поэтому запрос переживёт
-- и один проход, и другие имена ключей верхнего уровня.
-- Текст в кавычках («…», "…", `…`) выкидывается до поиска: там судья цитирует
-- ответ модели, и слово «память» в цитате упоминанием памяти не считается.
-- Маркер попадает в выдачу, только если он сработал: is_present == true И в его
-- тексте (explanation / reasoning) есть память. Переключается флагом
-- _REQUIRE_IS_PRESENT в UDF.
-- Маркеры из _IGNORE_MARKERS (subjectivity) пропускаются вовсе: если память
-- нашлась только в них, has_memory_A / has_memory_B будут false.
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

# Цитаты не считаем: «память» внутри кавычек — это судья цитирует ответ модели,
# а не рассуждает про память. Поставь False, чтобы учитывать и цитаты тоже.
_IGNORE_QUOTED = True

# Пары кавычек, содержимое которых вырезается перед поиском.
# Одиночная прямая кавычка (') намеренно не включена: апостроф в тексте
# склеился бы со следующим и выел кусок рассуждения.
_QUOTED_RE = re.compile(
    r'«[^«»]*»'          # «ёлочки»
    r'|„[^„“”]*[“”]'     # „лапки“
    r'|“[^“”]*”'         # “англ. двойные”
    r'|"[^"]*"'          # "прямые"
    r"|‘[^‘’]*’"         # ‘одинарные типографские’
    r'|`[^`]*`',         # `бэктики`
    re.S
)

# Считаем только сработавшие маркеры: is_present == true И память в тексте.
# Маркеры с is_present: false и маркеры без этого флага (аспекты со score)
# пропускаются. Поставь False, чтобы читать ризонинги всех маркеров подряд.
_REQUIRE_IS_PRESENT = True

# Под каким ключом внутри маркера лежит булев флаг. В этом пайплайне — is_present.
_FLAG_KEYS = ('is_present', 'present', 'triggered', 'is_on', 'value', 'flag')

# Маркеры, которые не считаются упоминанием памяти, даже если сработали и память
# в их тексте есть. Память только в них -> has_memory false, в списке пусто.
_IGNORE_MARKERS = ('subjectivity',)

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


def _has_memory(text):
    """Память упомянута вне цитат."""
    if _IGNORE_QUOTED:
        text = _QUOTED_RE.sub(' ', text)
    return bool(_MEMORY_RE.search(text))


def _is_on(value):
    """True/False, если у маркера есть булев флаг; None — если флага нет (маркер со score)."""
    if isinstance(value, bool):
        return value
    if isinstance(value, dict):
        for key in _FLAG_KEYS:
            flag = value.get(key)
            if isinstance(flag, bool):
                return flag
            if isinstance(flag, str) and flag.strip().lower() in ('true', 'false', 'да', 'нет'):
                return flag.strip().lower() in ('true', 'да')
    return None


def _hits(review):
    """Имена маркеров одного review, в reasoning которых есть память."""
    if not isinstance(review, dict):
        return []
    markers = review.get('markers')
    if not isinstance(markers, dict):
        return []

    names = []
    for name, value in markers.items():
        if str(name) in _IGNORE_MARKERS:
            continue
        if _REQUIRE_IS_PRESENT and _is_on(value) is not True:
            continue
        if any(_has_memory(t) for t in _strings(value, [])):
            names.append(str(name))
    return names


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

-- Ключ из input_meta. AutoConvert приводит и число, и строку; COALESCE — страховка.
$meta_iid = ($m) -> {
    RETURN COALESCE(
        Yson::LookupString($m, 'instruct_id'),
        CAST(Yson::LookupInt64($m, 'instruct_id') AS String)
    );
};

-- ЕДИНСТВЕННОЕ МЕСТО, ГДЕ НАЗВАН raw_tov. "Member not found" — правится здесь.
-- Если raw_tov лежит обычной строкой, а не Yson/Json:
--   CAST(t.raw_tov AS Utf8)
$judge = (
    SELECT
        $meta_iid(t.input_meta)                                     AS join_id,
        CAST(Yson::SerializeJson(t.raw_tov) AS Utf8)                AS raw_text
    FROM $input2 AS t
);

$scanned = (
    SELECT
        b.*,
        Yson::ParseJson($memory_scan(j.raw_text)) AS mem
    FROM (SELECT CAST(t.instruct_id AS String) AS join_id, t.* FROM $input1 AS t) AS b
    LEFT JOIN $judge AS j
    ON b.join_id = j.join_id
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
    WITHOUT IF EXISTS s.mem, s.join_id
FROM $scanned AS s;
