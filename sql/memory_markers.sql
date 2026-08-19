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
-- Текст в кавычках («…», "…", `…`) выкидывается до поиска: там судья цитирует
-- ответ модели, и слово «память» в цитате упоминанием памяти не считается.
-- Маркер попадает в выдачу, только если он сработал: is_present == true И в его
-- тексте (explanation / reasoning) есть память. Переключается флагом
-- _REQUIRE_IS_PRESENT в UDF.
-- Маркеры из _IGNORE_MARKERS (subjectivity) не считаются вовсе: если память
-- нашлась только в них, has_memory_A / has_memory_B будут false.
--
-- Выход (по 4 колонки на ответ):
--   has_memory_A / has_memory_B          — Bool: память упомянута хоть в одном reasoning
--   memory_markers_A / memory_markers_B  — List<String>: маркеры, где она упомянута
--   memory_markers_A_str / ..._B_str     — те же списки строкой, чтобы читалось в UI
--   memory_evidence_A / ..._B           — почему маркер попал: слово и кусок текста вокруг
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
# в тексте есть. Если память нашлась только в них — has_memory будет false.
_IGNORE_MARKERS = ('subjectivity',)

# Сколько символов текста показывать вокруг найденного слова в колонке-объяснении.
_EVIDENCE_PAD = 60

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


def _memory_match(text):
    """Первое совпадение вне цитат: (слово, кусок текста вокруг). Иначе None."""
    if _IGNORE_QUOTED:
        text = _QUOTED_RE.sub(' ', text)
    m = _MEMORY_RE.search(text)
    if m is None:
        return None
    left = max(0, m.start() - _EVIDENCE_PAD)
    right = min(len(text), m.end() + _EVIDENCE_PAD)
    around = ' '.join(text[left:right].split())
    if left > 0:
        around = '…' + around
    if right < len(text):
        around = around + '…'
    return m.group(0), around


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
    """[(маркер, найденное слово, кусок текста вокруг)] для одного review."""
    if not isinstance(review, dict):
        return []
    markers = review.get('markers')
    if not isinstance(markers, dict):
        return []

    hits = []
    for name, value in markers.items():
        if str(name) in _IGNORE_MARKERS:
            continue
        if _REQUIRE_IS_PRESENT and _is_on(value) is not True:
            continue
        for text in _strings(value, []):
            found = _memory_match(text)
            if found is not None:
                hits.append((str(name), found[0], found[1]))
                break
    return hits


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
    result = {'A': {'has': False, 'markers': [], 'evidence': []},
              'B': {'has': False, 'markers': [], 'evidence': []}}

    data = _parse(raw)
    if data is None:
        return json.dumps(result, ensure_ascii=False)

    passes = _passes(data)
    multi = len(passes) > 1

    for side in ('A', 'B'):
        names, evidence, seen = [], [], set()
        for pass_name, block in passes:
            review = block.get('review_' + side)
            if review is None:
                review = block.get('review_' + side.lower())
            prefix = (str(pass_name) + '.') if (multi and pass_name) else ''
            for name, word, around in _hits(review):
                full = prefix + name
                if full not in seen:
                    seen.add(full)
                    names.append(full)
                    evidence.append(full + ' [' + word + ']: ' + around)
        result[side] = {'has': bool(names), 'markers': names, 'evidence': evidence}

    return json.dumps(result, ensure_ascii=False)
@@;

$memory_scan = Python3::memory_scan($script);

$has     = ($mem, $side) -> { RETURN Yson::ConvertToBool(Yson::Lookup(Yson::Lookup($mem, $side), 'has')) ?? false; };
$list = ($mem, $side, $key) -> {
    RETURN COALESCE(
        Yson::ConvertToStringList(Yson::Lookup(Yson::Lookup($mem, $side), $key)),
        ListCreate(String)
    );
};
$markers  = ($mem, $side) -> { RETURN $list($mem, $side, 'markers'); };
$evidence = ($mem, $side) -> { RETURN $list($mem, $side, 'evidence'); };

$scanned = (
    SELECT
        t.*,
        -- raw_tov лежит как Yson/Json: сериализуем в текст и отдаём в UDF.
        -- Если в твоей таблице это обычная строка, замени на CAST(t.raw_tov AS Utf8).
        Yson::ParseJson($memory_scan(CAST(Yson::SerializeJson(t.raw_tov) AS Utf8))) AS mem
    FROM $input1 AS t
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    $has(s.mem, 'A')                                     AS has_memory_A,
    $markers(s.mem, 'A')                                 AS memory_markers_A,
    String::JoinFromList($markers(s.mem, 'A'), ', ')     AS memory_markers_A_str,
    String::JoinFromList($evidence(s.mem, 'A'), ' | ')   AS memory_evidence_A,

    $has(s.mem, 'B')                                     AS has_memory_B,
    $markers(s.mem, 'B')                                 AS memory_markers_B,
    String::JoinFromList($markers(s.mem, 'B'), ', ')     AS memory_markers_B_str,
    String::JoinFromList($evidence(s.mem, 'B'), ' | ')   AS memory_evidence_B,

    s.*
    WITHOUT IF EXISTS s.mem
FROM $scanned AS s;
