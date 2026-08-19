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
-- Предсказание: судья упомянул память хоть в одном маркере, кроме тех, что
-- перечислены в $judge_ignore (subjectivity). Правда: tov_flag = "да".
--
-- output1 — одна строка: precision, recall, f1 и числа, из которых они сложились.
-- output2 — по одной паре на строку: одна причина против одного маркера судьи,
--           tov_marker | judge_marker | cnt | tov_total | share_in_tov
--           Маркеры судьи отфильтрованы списком $judge_keep.

-- ===================== списки маркеров =====================

-- Известные названия причин. Нужны потому, что «Сенситивная память по теме,
-- но тяжеловесно» само содержит запятую: разбить строку просто по запятой
-- нельзя, название развалится на два куска.
-- Новое название разметки — дописать сюда.
$tov_known = AsList(
    'Сенситивная память по теме, но тяжеловесно',
    'Машинная формулировка',
    'Навязчивое повторение',
    'Эффект досье',
    'Запрещённые данные',
    'Запрещенные данные'
);

-- Маркеры судьи, которые вообще не считаются упоминанием памяти.
-- Если память нашлась только в них — строка идёт как «памяти нет»,
-- и на precision/recall она не влияет.
$judge_ignore = AsList(
    'subjectivity'
);

-- Маркеры судьи, которые интересны в разрезе причин (ВЫХОД 2).
$judge_keep = AsList(
    'template_phrases',
    'boundaries_violation',
    'stuffy_bureaucratic',
    'bad_intro'
);

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

$lower = ($v) -> {
    RETURN CAST(Unicode::ToLower(CAST(String::Strip(COALESCE(CAST($v AS String), '')) AS Utf8)) AS String);
};

-- Маркеры судьи обеих сторон в одном списке, без префикса прохода и без
-- игнорируемых. has_memory_A / has_memory_B намеренно не используются:
-- они не знают про $judge_ignore.
$judge_of = ($a, $b) -> {
    RETURN ListUniq(ListFilter(
        ListMap(ListExtend($split($a), $split($b)), $strip_pass),
        ($m) -> { RETURN NOT ListHas($judge_ignore, $m); }
    ));
};

$rows = (
    SELECT
        $lower(t.tov_flag) IN ('да', 'yes', 'true', '1')                    AS gold,

        -- предсказание: остался хоть один маркер после отсева игнорируемых
        ListLength($judge_of(t.memory_markers_A_str, t.memory_markers_B_str)) > 0 AS pred,

        -- если tov_markers лежит списком (Yson), замени на:
        -- CAST(String::JoinFromList(Yson::ConvertToStringList(t.tov_markers), ', ') AS String)
        COALESCE(CAST(t.tov_markers AS String), '')                         AS tov_raw,

        $judge_of(t.memory_markers_A_str, t.memory_markers_B_str)           AS judge_list
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

-- ===================== ВЫХОД 2: пары «причина — маркер» =====================

-- Сначала вынимаем известные названия целиком, остаток режем по запятой:
-- так название с запятой внутри остаётся целым, а незнакомое всё равно видно.
$parse_tov = ($s) -> {
    $t = COALESCE(CAST($s AS String), '');
    $found = ListFilter($tov_known, ($n) -> { RETURN String::Contains($t, $n); });
    $rest  = ListFold($found, $t, ($n, $acc) -> { RETURN String::ReplaceAll($acc, $n, ' '); });
    RETURN ListUniq(ListExtend($found, $split($rest)));
};

$pairs_src = (
    SELECT
        IF(ListLength(tov_parsed) > 0, tov_parsed, AsList('(пусто)'))          AS tov_list,
        IF(ListLength(judge_kept) > 0, judge_kept, AsList('(нет из списка)'))  AS judge_list
    FROM (
        SELECT
            $parse_tov(tov_raw)                                                     AS tov_parsed,
            ListSort(ListUniq(ListFilter(judge_list, ($m) -> { RETURN ListHas($judge_keep, $m); }))) AS judge_kept
        FROM $rows
        WHERE gold OR pred
    )
);

-- Два FLATTEN подряд: один FLATTEN по двум колонкам склеил бы списки попарно,
-- а нужны все сочетания причина × маркер.
$e1 = (
    SELECT tov_marker AS tov_marker, judge_list AS judge_list
    FROM $pairs_src
    FLATTEN LIST BY (tov_list AS tov_marker)
);

$e2 = (
    SELECT tov_marker AS tov_marker, judge_marker AS judge_marker
    FROM $e1
    FLATTEN LIST BY (judge_list AS judge_marker)
);

$pair_cnt = (
    SELECT tov_marker AS tov_marker, judge_marker AS judge_marker, CAST(COUNT(*) AS Int64) AS cnt
    FROM $e2
    GROUP BY tov_marker, judge_marker
);

$tov_tot = (
    SELECT tov_marker AS tov_marker, CAST(COUNT(*) AS Int64) AS total
    FROM $e2
    GROUP BY tov_marker
);

-- ORDER BY здесь намеренно нет: сортировка по убыванию при вставке в YT
-- добавляет служебную колонку _yql_column_0. Сортируй в UI по cnt.
INSERT INTO $output2 WITH TRUNCATE
SELECT
    p.tov_marker            AS tov_marker,
    p.judge_marker          AS judge_marker,
    p.cnt                   AS cnt,
    t.total                 AS tov_total,
    1.0 * p.cnt / t.total   AS share_in_tov
FROM $pair_cnt AS p
INNER JOIN $tov_tot AS t
ON p.tov_marker = t.tov_marker;
