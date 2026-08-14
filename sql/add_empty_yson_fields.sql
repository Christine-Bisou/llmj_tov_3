PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA yt.InferSchema = '1';

-- Копия таблицы плюс четыре Yson-поля. Значения появятся позже,
-- сейчас нужна только схема, поэтому пишем пустые контейнеры:
-- список для answers / input_final_messages, словарь для input_meta / input_render_data.
--
-- 1 — пейрвайз, 2 — поинтвайз по ответу A, 3 — поинтвайз по ответу B.

DECLARE $input1 AS String;   -- pairwise
DECLARE $output1 AS String;
DECLARE $input2 AS String;   -- pointwise A
DECLARE $output2 AS String;
DECLARE $input3 AS String;   -- pointwise B
DECLARE $output3 AS String;

$empty_list = Yson::ParseJson('[]');
$empty_map  = Yson::ParseJson('{}');

INSERT INTO $output1 WITH TRUNCATE
SELECT
    t.* WITHOUT if exists
        t.answers,
        t.input_final_messages,
        t.input_meta,
        t.input_render_data,

    $empty_list AS answers,
    $empty_list AS input_final_messages,
    $empty_map  AS input_meta,
    $empty_map  AS input_render_data
FROM $input1 AS t;

INSERT INTO $output2 WITH TRUNCATE
SELECT
    t.* WITHOUT if exists
        t.answers,
        t.input_final_messages,
        t.input_meta,
        t.input_render_data,

    $empty_list AS answers,
    $empty_list AS input_final_messages,
    $empty_map  AS input_meta,
    $empty_map  AS input_render_data
FROM $input2 AS t;

INSERT INTO $output3 WITH TRUNCATE
SELECT
    t.* WITHOUT if exists
        t.answers,
        t.input_final_messages,
        t.input_meta,
        t.input_render_data,

    $empty_list AS answers,
    $empty_list AS input_final_messages,
    $empty_map  AS input_meta,
    $empty_map  AS input_render_data
FROM $input3 AS t;
