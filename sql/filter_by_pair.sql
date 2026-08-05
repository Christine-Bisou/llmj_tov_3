PRAGMA SimpleColumns;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;
DECLARE $output2 AS String;

-- Оставляем из $input1 только те строки, чей ключ встречается в $input2.
-- Колонки берём целиком из первой таблицы, из второй не тянем ничего — она
-- нужна только как список ключей.
--
-- Ключ: real_instruct_id + оба ответа + оба сорса.
-- Пары ответов мало: один и тот же текст могут выдать две разные модели, и
-- тогда строки склеятся не с теми. real_instruct_id прижимает пару к своему
-- заданию, сорсы — к своим моделям.
--
-- LEFT SEMI, а не INNER: семантика «есть хотя бы одно совпадение». INNER JOIN
-- размножил бы строку первой таблицы столько раз, сколько совпадений нашлось
-- во второй, и на перезапусках пула это молча раздувает выход.

-- Каждый кусок ключа — к String и без NULL. Два повода:
-- если в одной таблице колонка Utf8, а в другой String, джойн по разным типам
-- не сойдётся; и NULL не равен NULL, так что без COALESCE строки с пустым
-- полем не нашлись бы молча.
$k = ($v) -> {
    RETURN COALESCE(CAST($v AS String), '');
};

-- Ответы длинные, а частей ключа пять — держать это пятью колонками джойна
-- дорого. Склеиваем через \x1f (в тексте ответа такого байта не бывает,
-- в отличие от \t) и берём md5: сравнение идёт по 32 байтам вместо килобайтов.
--
-- Чтобы ослабить ключ — уберите ненужную строку из конкатенации в ОБОИХ
-- местах, где вызывается $row_key. Если в $input2 нет real_instruct_id,
-- начинать надо с неё.
$row_key = ($id, $a1, $a2, $s1, $s2) -> {
    RETURN Digest::Md5Hex(
        $k($id) || '\x1f' ||
        $k($a1) || '\x1f' ||
        $k($a2) || '\x1f' ||
        $k($s1) || '\x1f' ||
        $k($s2)
    );
};

$left = (
    SELECT
        t.*,
        $row_key(
            t.real_instruct_id,
            t.answer_1, t.answer_2,
            t.answer_source_1, t.answer_source_2
        ) AS rk
    FROM $input1 AS t
);

$right = (
    SELECT
        $row_key(
            t.real_instruct_id,
            t.answer_1, t.answer_2,
            t.answer_source_1, t.answer_source_2
        ) AS rk
    FROM $input2 AS t
);

-- Совпавшие строки.
INSERT INTO $output1 WITH TRUNCATE
SELECT a.* WITHOUT a.rk
FROM $left AS a
LEFT SEMI JOIN $right AS b
ON a.rk == b.rk;

-- Остаток: строки из $input1, которых во второй таблице не нашлось.
-- Ключ строгий, и промах теперь может быть не только «такой пары там нет», но и
-- «сорсы записаны иначе» или «real_instruct_id проставлен не везде». Поэтому
-- остаток стоит смотреть глазами: пустой $output1 при полном $output2 значит,
-- что ключ слишком строгий, а не что пересечения нет.
-- Если не нужен — удалите блок целиком.
INSERT INTO $output2 WITH TRUNCATE
SELECT a.* WITHOUT a.rk
FROM $left AS a
LEFT ONLY JOIN $right AS b
ON a.rk == b.rk;
