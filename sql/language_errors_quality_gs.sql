-- Качество прохода по речевым ошибкам против золота из target_markup.
-- Отличие от language_errors_quality: золото здесь не чекбоксы разметки, а вердикт
-- голденсета — {"task": "russian_language_problem", "verdict": 0|1|2}.
-- Склейка с ответами джаджа идёт по instruct_id.
--
-- Вход:  $input1 — ответы джаджа (instruct_id, dst — сырой ответ модели);
--        $input2 — голденсет (instruct_id, target_markup).
-- Выход: одна строка с матрицей ошибок и метриками.

PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;

$script = @@#py
import json
import cyson


def _clean(s):
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
    return s.strip()


# Достаёт is_present у language_errors. Терпим к тому, что модель могла
# вернуть строку вместо булева и что ключа может не быть вовсе.
def _flag(data, markers_key):
    markers = data.get(markers_key) or {}
    if not isinstance(markers, dict):
        return False
    node = markers.get('language_errors') or {}
    if not isinstance(node, dict):
        return False
    val = node.get('is_present', False)
    if isinstance(val, bool):
        return val
    if isinstance(val, str):
        return val.strip().lower() in ('true', 'yes', '1')
    return bool(val)


# Возвращает {ok, p1, p2}. ok=false означает, что ответ не распарсился:
# без этого флага сломанный JSON молча засчитался бы как «ошибок нет»
# и просадил бы recall, не оставив следа в метриках.
#
# Докстринг — это сигнатура для YQL, и ничего кроме неё там быть не может:
# любой лишний текст падает как "Expected end of string" при выводе типа.
def parse_language_errors(s):
    """
    (String?) -> Yson?
    """
    s = _clean(s)
    if not s:
        return cyson.dumps({'ok': False, 'p1': False, 'p2': False})
    try:
        data = json.loads(s, strict=False)
        if not isinstance(data, dict):
            raise ValueError('not an object')
        return cyson.dumps({
            'ok': True,
            'p1': _flag(data, 'model_1_markers'),
            'p2': _flag(data, 'model_2_markers'),
        })
    except Exception:
        return cyson.dumps({'ok': False, 'p1': False, 'p2': False})
@@;

$parse_le = Python3::parse_language_errors($script);

-- Золото: verdict = 0 — речевых ошибок нет, 1 и выше — есть.
-- Строки без вердикта отбрасываем, иначе NULL стал бы «золотым false»
-- и разбавил бы отрицательный класс.
$gold = (
    SELECT
        g.instruct_id                                  AS instruct_id,
        Yson::ConvertToInt64(g.target_markup['verdict']) AS verdict
    FROM $input2 AS g
);

$gold_ = (
    SELECT
        instruct_id,
        verdict >= 1 AS gs_language
    FROM $gold
    WHERE verdict IS NOT NULL
);

$parsed = (
    SELECT
        $parse_le(p.dst) AS le,
        g.gs_language    AS gs_language
    FROM $input1 AS p
    INNER JOIN $gold_ AS g
    ON p.instruct_id = g.instruct_id
);

-- Ответы в паре одинаковые (голденсет размножен в answer_1/answer_2), поэтому
-- обе стороны сравниваются с одним и тем же золотом. Расхождение сторон при
-- идентичных ответах — это шум джаджа, его считаем отдельно.
$rows = (
    SELECT
        Yson::LookupBool(le, 'ok') ?? false AS ok,
        (Yson::LookupBool(le, 'p1') ?? false) != (Yson::LookupBool(le, 'p2') ?? false) AS sides_disagree,
        AsList(
            <|
                side: 'A',
                g: gs_language,
                p: Yson::LookupBool(le, 'p1') ?? false
            |>,
            <|
                side: 'B',
                g: gs_language,
                p: Yson::LookupBool(le, 'p2') ?? false
            |>
        ) AS pair
    FROM $parsed
);

$flat = (
    SELECT
        ok,
        pair.side AS side,
        pair.g    AS golden,
        pair.p    AS pred
    FROM $rows
    FLATTEN BY pair
);

$confusion = (
    SELECT
        SUM(IF(golden AND pred, 1, 0))         AS TP,
        SUM(IF(NOT golden AND pred, 1, 0))     AS FP,
        SUM(IF(golden AND NOT pred, 1, 0))     AS FN,
        SUM(IF(NOT golden AND NOT pred, 1, 0)) AS TN,
        COUNT(*)                               AS answers_total,
        SUM(IF(NOT ok, 1, 0))                  AS parse_failed
    FROM $flat
);

-- Пар (строк) вдвое меньше, чем единиц оценки, поэтому расхождение сторон
-- считаем по $rows, а не по $flat.
$consistency = (
    SELECT
        COUNT(*)                          AS pairs_total,
        SUM(IF(sides_disagree, 1, 0))     AS pairs_sides_disagree
    FROM $rows
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    'language_errors_vs_gs' AS marker,

    c.TP AS TP, c.FP AS FP, c.FN AS FN, c.TN AS TN,

    (1.0 * c.TP) / MAX_OF(1.0, 1.0 * (c.TP + c.FP))            AS Precision,
    (1.0 * c.TP) / MAX_OF(1.0, 1.0 * (c.TP + c.FN))            AS Recall,
    (1.0 * (c.TP + c.TN)) / MAX_OF(1.0, 1.0 * c.answers_total) AS Accuracy,
    (2.0 * c.TP) / MAX_OF(1.0, 2.0 * c.TP + c.FP + c.FN)       AS F1_Score,

    -- Базовые ставки: без них P/R не читаются. golden_rate — доля ответов,
    -- где ошибка есть в золоте; pred_rate — доля, где её нашла модель.
    c.TP + c.FN                                                 AS golden_positives,
    c.TP + c.FP                                                 AS predicted_positives,
    (1.0 * (c.TP + c.FN)) / MAX_OF(1.0, 1.0 * c.answers_total)  AS golden_rate,
    (1.0 * (c.TP + c.FP)) / MAX_OF(1.0, 1.0 * c.answers_total)  AS pred_rate,

    c.answers_total AS answers_total,
    c.parse_failed  AS parse_failed,

    -- шум джаджа: одинаковым ответам выставлены разные вердикты
    k.pairs_total          AS pairs_total,
    k.pairs_sides_disagree AS pairs_sides_disagree,
    (1.0 * k.pairs_sides_disagree) / MAX_OF(1.0, 1.0 * k.pairs_total) AS sides_disagree_rate
FROM $confusion AS c
CROSS JOIN $consistency AS k;
