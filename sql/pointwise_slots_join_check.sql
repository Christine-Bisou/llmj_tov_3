DECLARE $input1 AS String;
DECLARE $input2 AS String;

PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

-- Диагностика джойна слотов: почему склейка по (instruct_id, answer_source_1,
-- answer_source_2) не собирается. Ничего не пишет, только показывает.
-- Запускать на тех же таблицах, что и pointwise_slots_merge.sql.

-- 1) Что вообще лежит в answer_slot. Если справа нет строк со слотом 2 —
--    или слот приехал строкой '2', а не числом — джойн пуст ещё до сорсов.
SELECT
    'input1'      AS side,
    answer_slot   AS answer_slot,
    COUNT(*)      AS cnt
FROM $input1
GROUP BY answer_slot

UNION ALL

SELECT
    'input2'      AS side,
    answer_slot   AS answer_slot,
    COUNT(*)      AS cnt
FROM $input2
GROUP BY answer_slot;

-- 2) Сколько строк в каждом слоте и сколько среди них разных заданий.
--    cnt заметно больше ids — значит на задание приходится несколько пар,
--    и джойн по одному instruct_id обязан был давать дубли.
SELECT
    'input1 slot=1'             AS side,
    COUNT(*)                    AS cnt,
    COUNT(DISTINCT instruct_id) AS ids
FROM $input1
WHERE answer_slot == 1

UNION ALL

SELECT
    'input2 slot=2'             AS side,
    COUNT(*)                    AS cnt,
    COUNT(DISTINCT instruct_id) AS ids
FROM $input2
WHERE answer_slot == 2;

-- 3) Главное: сцепляем слоты по одному instruct_id и смотрим, как соотносятся
--    сорсы слева и справа. Читать так:
--      ok        — совпадают в том же порядке, джойн по сорсам обязан работать;
--      swapped   — справа переставлены местами, нужен джойн по паре без порядка;
--      null      — где-то пусто, а NULL не равен NULL, такие строки джойн теряет;
--      different — разные значения: либо форматирование (регистр, пробелы),
--                  либо на задание приходится несколько разных пар моделей.
$cmp = (
    SELECT
        a.instruct_id                     AS instruct_id,
        CAST(a.answer_source_1 AS String) AS a_src_1,
        CAST(a.answer_source_2 AS String) AS a_src_2,
        CAST(b.answer_source_1 AS String) AS b_src_1,
        CAST(b.answer_source_2 AS String) AS b_src_2,
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
    FROM (SELECT * FROM $input1 WHERE answer_slot == 1) AS a
    INNER JOIN (SELECT * FROM $input2 WHERE answer_slot == 2) AS b
    USING (instruct_id)
);

SELECT verdict AS verdict, COUNT(*) AS cnt
FROM $cmp
GROUP BY verdict
ORDER BY cnt DESC;

-- 4) Живые примеры всего, что не 'ok' — видно регистр, пробелы и пустые строки.
SELECT *
FROM $cmp
WHERE verdict != 'ok'
LIMIT 50;
