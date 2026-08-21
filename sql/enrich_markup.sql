PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;   -- основная таблица: ключ лежит внутри input_meta.instruct_id
DECLARE $input2 AS String;   -- разметка: instruct_id, "есть проблема в ToV?", user_facts, bucket
DECLARE $output1 AS String;  -- та же основная таблица + три колонки из разметки

-- "Да" -> true, "Нет" -> false. Всё остальное (пусто, "затрудняюсь", опечатки)
-- остаётся NULL: молча превращать неизвестное в false нельзя, это портит метрику.
-- Колонки разметки считаем обычными строками (выгрузка из шитов/Толоки).
-- Если они приедут Yson-ом, CAST здесь надо заменить на Yson::ConvertToString.
$to_bool = ($value) -> {
    $text = Unicode::ToLower(CAST(String::Strip(CAST($value AS String) ?? "") AS Utf8));
    RETURN CASE $text
        WHEN "да"u  THEN true
        WHEN "нет"u THEN false
        ELSE NULL
    END;
};

-- Ключ первой таблицы достаём из Yson-мапы input_meta.
$left = (
    SELECT
        Yson::ConvertToString(input_meta["instruct_id"]) AS instruct_id,
        t.*,
        WITHOUT IF EXISTS
            t._other, t.instruct_id, t.tov_memory, t.user_facts, t.bucket
    FROM $input1 AS t
);

-- В разметке на один instruct_id может прийти несколько строк (перекрытие
-- разметчиков, переоткрытые задания). Схлопываем до одной, иначе LEFT JOIN
-- размножит строки основной таблицы.
$markup = (
    SELECT
        instruct_id,
        SOME($to_bool(`есть проблема в ToV?`)) AS tov_memory,
        SOME(user_facts)                       AS user_facts,
        SOME(bucket)                           AS bucket
    FROM $input2
    GROUP BY CAST(instruct_id AS String) AS instruct_id
);

-- LEFT JOIN: строки без разметки остаются в выдаче с NULL в трёх колонках.
INSERT INTO $output1 WITH TRUNCATE
SELECT
    m.tov_memory AS tov_memory,
    m.user_facts AS user_facts,
    m.bucket     AS bucket,
    l.*
FROM $left AS l
LEFT JOIN $markup AS m
USING (instruct_id);
