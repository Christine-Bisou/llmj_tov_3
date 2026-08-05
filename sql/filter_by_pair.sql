PRAGMA SimpleColumns;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;
DECLARE $output2 AS String;

-- Оставляем из $input1 только те строки, чья пара (answer_1, answer_2)
-- встречается в $input2. Колонки берём целиком из первой таблицы, из второй
-- не тянем ничего — она нужна только как список ключей.
--
-- LEFT SEMI, а не INNER: семантика «есть хотя бы одно совпадение». INNER JOIN
-- размножил бы строку первой таблицы столько раз, сколько совпадений нашлось
-- во второй, и на перезапусках пула это молча раздувает выход.
--
-- Ключ приводим к String с обеих сторон: если в одной таблице колонка Utf8,
-- а в другой String, джойн по разным типам не сойдётся. COALESCE — чтобы
-- строки с пустым answer не выпадали молча: NULL не равен NULL, и без него
-- они бы просто не нашлись.

$key = ($v) -> {
    RETURN COALESCE(CAST($v AS String), '');
};

$left = (
    SELECT
        t.*,
        $key(t.answer_1) AS k1,
        $key(t.answer_2) AS k2
    FROM $input1 AS t
);

$right = (
    SELECT
        $key(t.answer_1) AS k1,
        $key(t.answer_2) AS k2
    FROM $input2 AS t
);

-- Совпавшие строки.
INSERT INTO $output1 WITH TRUNCATE
SELECT a.* WITHOUT a.k1, a.k2
FROM $left AS a
LEFT SEMI JOIN $right AS b
ON a.k1 == b.k1 AND a.k2 == b.k2;

-- Остаток: пары из $input1, которых во второй таблице не нашлось.
-- Нужен, чтобы отличить «во второй таблице их и не было» от «джойн не сошёлся
-- по типу или по перестановке ответов». Если не нужен — удалите блок целиком.
INSERT INTO $output2 WITH TRUNCATE
SELECT a.* WITHOUT a.k1, a.k2
FROM $left AS a
LEFT ONLY JOIN $right AS b
ON a.k1 == b.k1 AND a.k2 == b.k2;
