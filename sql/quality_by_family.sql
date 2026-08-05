PRAGMA yt.InferSchema = '1';
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;

DECLARE $input1 AS String;
DECLARE $output1 AS String;

-- Качество вердикта в разрезе семейств моделей.
--
-- Вход — таблица после склейки второго этапа: разметка из пула (winner,
-- answer_source_1, answer_source_2, family_1, family_2) плюс вердикт джаджа
-- (tov_winner).
--
-- Разбивка та же, что и была — vlm / neuro / all, — но семейство читается из
-- колонок family_1 / family_2, а не выводится из имён моделей.
--
-- Строка 'other' в выходе появляется, только если в family_* лежит что-то
-- третье. Раньше такие строки отфильтровывались и молча растворялись в 'all';
-- теперь их видно, и по ним сразу понятно, что поле заполнено не так, как
-- ожидает запрос. Если 'other' пустой — в таблице ровно три строки.
--
-- golden = winner     (имя модели-победителя из разметки)
-- model  = tov_winner (то, что поставил джадж: model_1 / model_2 / tie / conflict)
-- Обе стороны нормализуются в left / right / draw / both_bad через
-- answer_source_1 и answer_source_2 — колонок source_A / source_B в этой схеме нет.
--
-- Метрики:
--   quality_strict            — совпадение вердиктов (draw и both_bad считаем одним и тем же)
--   quality_with_half         — то же, но «ничья против выбора» засчитывается за половину
--   quality_strict_no_draw    — strict только по строкам, где разметка выбрала сторону
--   quality_with_half_no_draw — half   только по ним же
--
-- Зачем последние две: ничьи в разметке разбавляют метрику. Джадж, который
-- всегда говорит «ничья», на пуле с большой долей ничьих выглядит прилично,
-- хотя ни одного выбора не сделал. Метрики _no_draw смотрят ровно на те строки,
-- где выбор был обязателен, и такой джадж проваливается на них честно.
-- Знаменатель у обеих — cnt_no_draw, строки с golden draw / both_bad в них не идут.
--
-- Строки, где сторону определить нельзя, в метрики не идут и видны
-- в skipped_model / skipped_golden.

$norm_side = Python3::norm_side(
    Callable<(Utf8?, Utf8?, Utf8?)->Utf8>,
@@
def _n(x):
    return " ".join(str(x or "").strip().lower().split())

_DRAW     = {"draw", "tie", "equal", "conflict"}
_BOTH_BAD = {"both_bad", "bothbad", "both_worse"}
# 'answer_a' / 'answer_b' — то, что реально лежит в golden_winner
_LEFT     = {"left", "first", "a", "1", "answer_1", "answer_a", "model_1"}
_RIGHT    = {"right", "second", "b", "2", "answer_2", "answer_b", "model_2"}

def norm_side(w, s1, s2):
    w, a, b = _n(w), _n(s1), _n(s2)
    if not w:
        return "unknown"
    if w in _DRAW:
        return "draw"
    if w in _BOTH_BAD:
        return "both_bad"
    if w in _LEFT:
        return "left"
    if w in _RIGHT:
        return "right"
    if a and b and a == b:
        return "unknown"   # одна модель с обеих сторон — сторону не определить
    if w == a:
        return "left"
    if w == b:
        return "right"
    return "unknown"
@@
);

-- Бакеты те же, что и были: vlm / neuro. Но берутся из колонок family_1 /
-- family_2, а не из списка имён моделей — новая модель попадает в свой бакет
-- сама, без правки запроса.
$fam = ($v) -> {
    RETURN String::AsciiToLower(COALESCE(CAST($v AS String), ''));
};

-- Порядок проверок сохранён: vlm сильнее neuro, поэтому пара vlm против neuro
-- считается в vlm, как считалась раньше.
-- Сравниваем вхождением, а не равенством: если в поле лежит ровно 'vlm' —
-- разницы нет, а 'vlm_32b' или 'VLM' попадут куда надо, а не в other.
$row_family = ($f1, $f2) -> {
    $a = $fam($f1);
    $b = $fam($f2);
    RETURN CASE
        WHEN String::Contains($a, 'vlm')   OR String::Contains($b, 'vlm')   THEN 'vlm'
        WHEN String::Contains($a, 'neuro') OR String::Contains($b, 'neuro') THEN 'neuro'
        ELSE 'other'
    END;
};

$score_half = ($golden, $model) -> {
    RETURN CASE
        WHEN $golden == $model THEN 1.0
        WHEN ($golden == 'draw'     AND $model  == 'both_bad')
          OR ($golden == 'both_bad' AND $model  == 'draw')     THEN 1.0
        WHEN ($golden IN ('draw', 'both_bad') AND $model  NOT IN ('draw', 'both_bad'))
          OR ($model  IN ('draw', 'both_bad') AND $golden NOT IN ('draw', 'both_bad')) THEN 0.5
        ELSE 0.0
    END;
};

$score_strict = ($golden, $model) -> {
    RETURN CASE
        WHEN $golden == $model THEN 1.0
        WHEN ($golden == 'draw'     AND $model  == 'both_bad')
          OR ($golden == 'both_bad' AND $model  == 'draw')     THEN 1.0
        ELSE 0.0
    END;
};

-- 0/0 даёт NaN, а не пустую ячейку: семейство без размеченных строк должно
-- быть видно как NULL, иначе NaN утечёт в отчёт как «качество».
$ratio = ($sum, $cnt) -> {
    RETURN IF($cnt > 0, $sum / CAST($cnt AS Double), Nothing(Double?));
};

$sided = (
    SELECT
        $row_family(family_1, family_2) AS family,
        $norm_side(
            CAST(winner AS Utf8?),
            CAST(answer_source_1 AS Utf8?),
            CAST(answer_source_2 AS Utf8?)
        ) AS golden_side,
        $norm_side(
            CAST(tov_winner AS Utf8?),
            CAST(answer_source_1 AS Utf8?),
            CAST(answer_source_2 AS Utf8?)
        ) AS model_side
    FROM $input1
);

$scored = (
    SELECT
        family,
        golden_side,
        model_side,
        CASE WHEN golden_side != 'unknown' AND model_side != 'unknown'
             THEN $score_half(golden_side, model_side)
             ELSE Nothing(Double?) END AS s_half,
        CASE WHEN golden_side != 'unknown' AND model_side != 'unknown'
             THEN $score_strict(golden_side, model_side)
             ELSE Nothing(Double?) END AS s_strict,
        -- та же оценка, но только там, где разметка назвала победителя:
        -- golden draw / both_bad выпадают вместе с unknown
        CASE WHEN golden_side IN ('left', 'right') AND model_side != 'unknown'
             THEN $score_half(golden_side, model_side)
             ELSE Nothing(Double?) END AS s_half_nd,
        CASE WHEN golden_side IN ('left', 'right') AND model_side != 'unknown'
             THEN $score_strict(golden_side, model_side)
             ELSE Nothing(Double?) END AS s_strict_nd
    FROM $sided
);

-- Суммы и счётчики отдельно от долей: иначе знаменатель пришлось бы писать
-- дважды в каждой строке (алиас из того же SELECT в YQL не виден).
$by_family = (
    SELECT
        family                              AS family,
        SUM(s_half)                         AS sum_half,
        SUM(s_strict)                       AS sum_strict,
        SUM(s_half_nd)                      AS sum_half_nd,
        SUM(s_strict_nd)                    AS sum_strict_nd,
        COUNT_IF(s_half IS NOT NULL)        AS cnt,
        COUNT_IF(s_half_nd IS NOT NULL)     AS cnt_no_draw,
        COUNT(*)                            AS rows_total,
        COUNT_IF(model_side == 'unknown')   AS skipped_model,
        COUNT_IF(golden_side == 'unknown')  AS skipped_golden
    FROM $scored
    GROUP BY family
);

-- 'all' — те же строки без разбивки, для сверки итога.
$total = (
    SELECT
        'all'                               AS family,
        SUM(s_half)                         AS sum_half,
        SUM(s_strict)                       AS sum_strict,
        SUM(s_half_nd)                      AS sum_half_nd,
        SUM(s_strict_nd)                    AS sum_strict_nd,
        COUNT_IF(s_half IS NOT NULL)        AS cnt,
        COUNT_IF(s_half_nd IS NOT NULL)     AS cnt_no_draw,
        COUNT(*)                            AS rows_total,
        COUNT_IF(model_side == 'unknown')   AS skipped_model,
        COUNT_IF(golden_side == 'unknown')  AS skipped_golden
    FROM $scored
);

$agg = (
    SELECT * FROM $by_family
    UNION ALL
    SELECT * FROM $total
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    family,
    $ratio(sum_half,      cnt)         AS quality_with_half,
    $ratio(sum_strict,    cnt)         AS quality_strict,
    $ratio(sum_half_nd,   cnt_no_draw) AS quality_with_half_no_draw,
    $ratio(sum_strict_nd, cnt_no_draw) AS quality_strict_no_draw,
    cnt,
    cnt_no_draw,
    rows_total,
    skipped_model,
    skipped_golden
FROM $agg
ORDER BY family;
