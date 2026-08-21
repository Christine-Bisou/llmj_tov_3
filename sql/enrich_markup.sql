DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;
DECLARE $output2 AS String;

PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.InferSchema = '1';

-- Колонки второй таблицы могут приехать и Yson-ом, и обычной строкой:
-- CAST на Yson отдаёт бинарь и ключи не сходятся, ConvertToString на строке
-- отдаёт NULL. Берём то, что сработало.
$text = ($x) -> {
    RETURN Yson::ConvertToString($x) ?? CAST($x AS String);
};

INSERT INTO $output1
SELECT
    a.*,
    CASE $text(b.`есть проблема в ToV?`)
        WHEN "Да"  THEN true
        WHEN "Нет" THEN false
        ELSE NULL
    END          AS tov_memory,
    b.user_facts AS user_facts,
    b.bucket     AS bucket
FROM $input1 AS a
LEFT JOIN $input2 AS b
-- слева instruct_id лежит внутри yson-мапы, это узел-ресурс, CAST его не берёт
ON Yson::ConvertToString(a.input_meta.instruct_id) = $text(b.req_id);
