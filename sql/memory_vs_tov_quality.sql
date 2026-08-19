PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;
DECLARE $output1 AS String;
DECLARE $output2 AS String;

-- Вход: склеенная таблица с колонками
--   has_memory_A / has_memory_B              — судья упомянул память
--   memory_markers_A_str / ..._B_str         — "direct.template_phrases, reverse.template_phrases"
--   tov_flag                                 — разметка: "да" / "нет"
--   tov_markers                              — "Навязчивое повторение, Машинная формулировка"
--
-- Предсказание: has_memory_A OR has_memory_B. Правда: tov_flag = "да".
--
-- output1 — одна строка: precision, recall, f1 и числа, из которых они сложились.
-- output2 — сочетания причин и маркеров судьи с частотой:
--           tov_markers | judge_markers | cnt | share

-- ===================== разбор строк =====================

-- "a, b, c" -> ['a', 'b', 'c']. Пустые куски выкидываем.
$split = ($s) -> {
    RETURN ListFilter(
        ListMap(
            String::SplitToList(COALESCE(CAST($s AS String), ''), ','),
            ($x) -> { RETURN String::Strip($x); }
        ),
        ($x) -> { RETURN $x != ''; }
    );
};

-- "reverse.template_phrases" -> "template_phrases": проход для сопоставления не нужен.
$strip_pass = ($m) -> {
    RETURN IF(String::Contains($m, '.'), ListLast(String::SplitToList($m, '.')), $m);
};

-- Список -> строка через запятую. Сортировка и дедуп, чтобы "A, B" и "B, A"
-- считались одним сочетанием, а не двумя.
$join = ($lst, $empty) -> {
    RETURN IF(
        ListLength($lst) > 0,
        String::JoinFromList(ListSort(ListUniq($lst)), ', '),
        $empty
    );
};

$lower = ($v) -> {
    RETURN CAST(Unicode::ToLower(CAST(String::Strip(COALESCE(CAST($v AS String), '')) AS Utf8)) AS String);
};

$rows = (
    SELECT
        $lower(t.tov_flag) IN ('да', 'yes', 'true', '1')                    AS gold,
        COALESCE(t.has_memory_A, false) OR COALESCE(t.has_memory_B, false)  AS pred,

        -- если tov_markers лежит списком (Yson), замени на:
        -- Yson::ConvertToStringList(t.tov_markers)
        $split(t.tov_markers)                                               AS tov_list,

        ListMap(
            ListExtend($split(t.memory_markers_A_str), $split(t.memory_markers_B_str)),
            $strip_pass
        )                                                                   AS judge_list
    FROM $input1 AS t
);

-- ===================== ВЫХОД 1: качество =====================

$conf = (
    SELECT
        CAST(COUNT(*) AS Int64)                        AS rows_total,
        CAST(COUNT_IF(pred AND gold) AS Int64)         AS tp,
        CAST(COUNT_IF(pred AND NOT gold) AS Int64)     AS fp,
        CAST(COUNT_IF(NOT pred AND gold) AS Int64)     AS fn,
        CAST(COUNT_IF(NOT pred AND NOT gold) AS Int64) AS tn
    FROM $rows
);

$with_pr = (
    SELECT
        c.*,
        IF(c.tp + c.fp > 0, 1.0 * c.tp / (c.tp + c.fp), 0.0) AS prec,
        IF(c.tp + c.fn > 0, 1.0 * c.tp / (c.tp + c.fn), 0.0) AS rec
    FROM $conf AS c
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    m.prec                                                              AS `precision`,
    m.rec                                                               AS recall,
    IF(m.prec + m.rec > 0, 2.0 * m.prec * m.rec / (m.prec + m.rec), 0.0) AS f1,

    m.rows_total                                                        AS rows_total,
    m.tp                                                                AS tp,
    m.fp                                                                AS fp,
    m.fn                                                                AS fn,
    m.tn                                                                AS tn,
    IF(m.rows_total > 0, 1.0 * (m.tp + m.tn) / m.rows_total, 0.0)       AS accuracy
FROM $with_pr AS m;

-- ===================== ВЫХОД 2: сочетания =====================

-- Строки, где хоть одна сторона что-то нашла: пары «пусто / пусто» (TN) не нужны.
-- Убери WHERE, если хочешь видеть и их.
$combos = (
    SELECT
        $join(tov_list, '(пусто)')   AS tov_markers,
        $join(judge_list, '(пусто)') AS judge_markers
    FROM $rows
    WHERE gold OR pred
);

$combos_total = (SELECT CAST(COUNT(*) AS Int64) FROM $combos);

INSERT INTO $output2 WITH TRUNCATE
SELECT
    tov_markers                                                        AS tov_markers,
    judge_markers                                                      AS judge_markers,
    CAST(COUNT(*) AS Int64)                                            AS cnt,
    IF($combos_total > 0, 1.0 * COUNT(*) / $combos_total, 0.0)         AS share
FROM $combos
GROUP BY tov_markers, judge_markers
ORDER BY cnt DESC, tov_markers, judge_markers;
