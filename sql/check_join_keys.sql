PRAGMA SimpleColumns;
PRAGMA yt.InferSchema = '2';

DECLARE $input1 AS String;   -- прямой прогон
DECLARE $input2 AS String;   -- обратный прогон

-- Проверка ключа джойна перед склейкой.
-- Джойн размножает строки ровно тогда, когда ключ не уникален: на каждый ключ
-- получается (строк слева × строк справа). Если max_rows_per_key = 1 с обеих
-- сторон — склейка один-к-одному и рост числа строк невозможен.

$left = (
    SELECT instruct_id, source_A, source_B, COUNT(*) AS n
    FROM $input1
    GROUP BY instruct_id, source_A, source_B
);

$right = (
    SELECT instruct_id, source_A, source_B, COUNT(*) AS n
    FROM $input2
    GROUP BY instruct_id, source_A, source_B
);

-- 1. Сводка по каждой таблице
SELECT 'direct' AS side,
       COUNT(*)  AS keys,
       SUM(n)    AS rows,
       MAX(n)    AS max_rows_per_key
FROM $left
UNION ALL
SELECT 'reversed', COUNT(*), SUM(n), MAX(n)
FROM $right;

-- 2. Сколько строк даст джойн по этому ключу
SELECT COUNT(*)      AS matched_keys,
       SUM(l.n * r.n) AS rows_after_join
FROM $left AS l
INNER JOIN $right AS r
USING (instruct_id, source_A, source_B);

-- 3. Ключи, которые всё ещё размножаются: их нужно добить в ключ джойна
--    (например, poolId — или разобраться, почему строка задвоилась на входе)
SELECT instruct_id,
       source_A,
       source_B,
       l.n       AS direct_rows,
       r.n       AS reversed_rows,
       l.n * r.n AS pair_rows
FROM $left AS l
INNER JOIN $right AS r
USING (instruct_id, source_A, source_B)
WHERE l.n > 1 OR r.n > 1
ORDER BY pair_rows DESC
LIMIT 50;
