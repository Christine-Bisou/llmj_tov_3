DECLARE $input1 AS String;
DECLARE $input2 AS String;

PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

-- Проверка джойна слотов: уникален ли instruct_id на каждом уровне и не
-- задваивает ли склейка строки. Ничего не пишет, только показывает.
-- Запускать на тех же таблицах, что и pointwise_slots_merge.sql.

$as_key = ($s) -> {
    RETURN COALESCE(CAST($s AS String), '');
};

$src_lo = ($a, $b) -> {
    RETURN IF($as_key($a) <= $as_key($b), $as_key($a), $as_key($b));
};

$src_hi = ($a, $b) -> {
    RETURN IF($as_key($a) <= $as_key($b), $as_key($b), $as_key($a));
};

-- Ключи склеиваем в строку: COUNT(DISTINCT ...) по одной строке надёжнее,
-- чем по кортежу, и печатается человекочитаемо.
$pair = ($a, $b) -> {
    RETURN $src_lo($a, $b) || '#' || $src_hi($a, $b);
};

$full_key = ($id, $a, $b) -> {
    RETURN COALESCE(CAST($id AS String), '') || '#' || $pair($a, $b);
};

$s1 = (
    SELECT
        t.instruct_id                                          AS instruct_id,
        $src_lo(t.answer_source_1, t.answer_source_2)          AS src_lo,
        $src_hi(t.answer_source_1, t.answer_source_2)          AS src_hi,
        $pair(t.answer_source_1, t.answer_source_2)            AS pair_key,
        $full_key(t.instruct_id, t.answer_source_1, t.answer_source_2) AS full_key
    FROM $input1 AS t
    WHERE t.answer_slot == 1
);

$s2 = (
    SELECT
        t.instruct_id                                          AS instruct_id,
        $src_lo(t.answer_source_1, t.answer_source_2)          AS src_lo,
        $src_hi(t.answer_source_1, t.answer_source_2)          AS src_hi,
        $pair(t.answer_source_1, t.answer_source_2)            AS pair_key,
        $full_key(t.instruct_id, t.answer_source_1, t.answer_source_2) AS full_key
    FROM $input2 AS t
    WHERE t.answer_slot == 2
);

-- ========================= 1. РАСПРЕДЕЛЕНИЕ ПО СЛОТАМ =========================
-- Если справа нет строк со слотом 2 (или слот приехал строкой '2', а не числом),
-- джойн пуст ещё до всяких сорсов.
SELECT 'input1' AS side, answer_slot AS answer_slot, COUNT(*) AS cnt
FROM $input1
GROUP BY answer_slot

UNION ALL

SELECT 'input2' AS side, answer_slot AS answer_slot, COUNT(*) AS cnt
FROM $input2
GROUP BY answer_slot;

-- ========================= 2. УНИКАЛЕН ЛИ instruct_id =========================
-- cnt == ids_only            — instruct_id уникален, джойна по нему достаточно;
-- cnt >  ids_only            — на задание несколько строк, по одному instruct_id
--                              джойнить нельзя, будет размножение;
-- cnt == ids_with_sources    — instruct_id + пара сорсов уникальны, ключ годится;
-- cnt >  ids_with_sources    — повторы есть даже с сорсами, нужен дедуп.
SELECT
    'input1 slot=1'              AS level,
    COUNT(*)                     AS cnt,
    COUNT(DISTINCT instruct_id)  AS ids_only,
    COUNT(DISTINCT full_key)     AS ids_with_sources
FROM $s1

UNION ALL

SELECT
    'input2 slot=2'              AS level,
    COUNT(*)                     AS cnt,
    COUNT(DISTINCT instruct_id)  AS ids_only,
    COUNT(DISTINCT full_key)     AS ids_with_sources
FROM $s2;

-- ========================= 3. КТО ИМЕННО ПОВТОРЯЕТСЯ =========================
-- Пусто — повторов нет. Если строки есть, смотри на pairs: pairs == cnt значит
-- в задании просто несколько разных пар моделей, и это лечится ключом;
-- pairs < cnt — настоящие повторы одной пары, тут нужен дедуп.
SELECT 'input1 slot=1' AS side, instruct_id AS instruct_id,
       COUNT(*) AS cnt, COUNT(DISTINCT pair_key) AS pairs
FROM $s1
GROUP BY instruct_id
HAVING COUNT(*) > 1
ORDER BY cnt DESC
LIMIT 20;

SELECT 'input2 slot=2' AS side, instruct_id AS instruct_id,
       COUNT(*) AS cnt, COUNT(DISTINCT pair_key) AS pairs
FROM $s2
GROUP BY instruct_id
HAVING COUNT(*) > 1
ORDER BY cnt DESC
LIMIT 20;

-- ========================= 4. ЧТО ДАЁТ САМ ДЖОЙН =========================
-- Главная таблица. Читать так:
--   «по instruct_id» больше, чем «левых строк»      — джойн задваивает;
--   «по instruct_id + сорсам» меньше «левых строк»  — джойн теряет строки,
--                                                     сорсы слева и справа
--                                                     не совпадают (см. п.5);
--   оба числа равны «левым строкам»                 — всё ровно, один к одному.
SELECT 'левых строк (slot=1)' AS what, COUNT(*) AS cnt FROM $s1

UNION ALL

SELECT 'правых строк (slot=2)' AS what, COUNT(*) AS cnt FROM $s2

UNION ALL

SELECT 'джойн по instruct_id' AS what, COUNT(*) AS cnt
FROM (SELECT a.instruct_id AS instruct_id FROM $s1 AS a INNER JOIN $s2 AS b USING (instruct_id))

UNION ALL

SELECT 'джойн по instruct_id + сорсам' AS what, COUNT(*) AS cnt
FROM (SELECT a.instruct_id AS instruct_id FROM $s1 AS a INNER JOIN $s2 AS b USING (instruct_id, src_lo, src_hi));

-- ========================= 5. ПОЧЕМУ НЕ СОШЛИСЬ СОРСЫ =========================
-- Сцепляем по одному instruct_id и сравниваем сорсы напрямую:
--   ok        — совпадают в том же порядке;
--   swapped   — справа переставлены (наш ключ это переживает);
--   null      — где-то пусто, NULL не равен NULL (наш ключ это переживает);
--   different — разные значения: регистр, пробелы или правда разные пары.
SELECT
    verdict      AS verdict,
    COUNT(*)     AS cnt,
    MIN(CAST(a.answer_source_1 AS String)) AS sample_a_src_1,
    MIN(CAST(a.answer_source_2 AS String)) AS sample_a_src_2,
    MIN(CAST(b.answer_source_1 AS String)) AS sample_b_src_1,
    MIN(CAST(b.answer_source_2 AS String)) AS sample_b_src_2
FROM (SELECT * FROM $input1 WHERE answer_slot == 1) AS a
INNER JOIN (SELECT * FROM $input2 WHERE answer_slot == 2) AS b
USING (instruct_id)
GROUP BY
    CASE
        WHEN a.answer_source_1 IS NULL OR a.answer_source_2 IS NULL
          OR b.answer_source_1 IS NULL OR b.answer_source_2 IS NULL
            THEN 'null'
        WHEN CAST(a.answer_source_1 AS String) = CAST(b.answer_source_1 AS String)
         AND CAST(a.answer_source_2 AS String) = CAST(b.answer_source_2 AS String)
            THEN 'ok'
        WHEN CAST(a.answer_source_1 AS String) = CAST(b.answer_source_2 AS String)
         AND CAST(a.answer_source_2 AS String) = CAST(b.answer_source_1 AS String)
            THEN 'swapped'
        ELSE 'different'
    END AS verdict
ORDER BY cnt DESC;
