PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;

-- Диагностика ключа склейки прямого и обратного прогонов.
-- Запускать ПЕРЕД judge_merge_pretty.sql, если склейка падает с
--     Unknown column: instruct_id in correlation name: i1
--
-- input1 — прямой прогон, input2 — обратный.
--
-- Задача: выяснить, есть ли в обеих таблицах общий ключ. Пока это не выяснено,
-- склеивать по ROW_NUMBER() нельзя: порядок строк в YT после инференса не
-- гарантирован, и позиционный JOIN тихо соединит РАЗНЫЕ пары — запрос отработает
-- без ошибки, а средние оценки и вердикты будут посчитаны по чужим строкам.

-- ========================= 1. Какие вообще есть колонки =========================
-- По одной строке из каждой таблицы целиком в JSON. Если Yson::From(TableRow())
-- споткнётся о сложный тип — заменить на обычный SELECT * ... LIMIT 1.

SELECT 'input1' AS side, Yson::SerializeJson(Yson::From(TableRow())) AS sample_row
FROM {{input1}}
LIMIT 1;

SELECT 'input2' AS side, Yson::SerializeJson(Yson::From(TableRow())) AS sample_row
FROM {{input2}}
LIMIT 1;

-- ========================= 2. Годится ли ключ по содержимому =========================
-- Хешируем каждый ответ отдельно и склеиваем хеши: разделитель не нужен,
-- в текст ответа он бы всё равно мог попасть.
-- answer_1 / answer_2 в обратном прогоне НЕ переставлены (переставлен только
-- infer_dialog), поэтому ключ одинаков с обеих сторон.

$pair_key = ($a1, $a2) -> {
    RETURN Digest::Md5Hex(COALESCE(CAST($a1 AS String), ''))
        || Digest::Md5Hex(COALESCE(CAST($a2 AS String), ''));
};

$k1 = (SELECT $pair_key(answer_1, answer_2) AS k FROM {{input1}});
$k2 = (SELECT $pair_key(answer_1, answer_2) AS k FROM {{input2}});

$rows_1 = (SELECT COUNT(*) FROM $k1);
$rows_2 = (SELECT COUNT(*) FROM $k2);
$keys_1 = (SELECT COUNT(DISTINCT k) FROM $k1);
$keys_2 = (SELECT COUNT(DISTINCT k) FROM $k2);
$matched = (SELECT COUNT(*) FROM (SELECT k FROM $k1 INTERSECT SELECT k FROM $k2));

SELECT
    $rows_1  AS rows_1,
    $keys_1  AS distinct_keys_1,   -- должно совпасть с rows_1
    $rows_2  AS rows_2,
    $keys_2  AS distinct_keys_2,   -- должно совпасть с rows_2
    $matched AS matched_keys;      -- должно совпасть с обоими

-- Как читать результат:
--   distinct_keys_N < rows_N  -> ключ не уникален, добавить в $pair_key диалог
--                                (Yson::SerializeJson(Yson::From(dialog)));
--   matched_keys   < min(...) -> прогоны сделаны по разным выборкам, склейка
--                                потеряет часть пар — разбираться с графом,
--                                а не с запросом.

-- ========================= 3. Примеры дублей =========================
-- Если ключ не уникален — вот на чём именно.

SELECT k, COUNT(*) AS cnt
FROM $k1
GROUP BY k
HAVING COUNT(*) > 1
ORDER BY cnt DESC
LIMIT 20;
