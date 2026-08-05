PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;

DECLARE $input1 AS String;   -- dialog: List<Struct<content, role>>, instruct: Utf8
DECLARE $input2 AS String;   -- dialog: Yson,                        instruct: String
DECLARE $output1 AS String;  -- сюда идёт склейка
DECLARE $output2 AS String;  -- не используется, см. хвост файла

-- Склейка двух входных таблиц в одну через UNION ALL.
--
-- Схемы совпадают по именам, но не по типам:
--   dialog   — слева List<Struct<content: Utf8, role: Utf8>>, справа Yson;
--   instruct — слева Utf8, справа String.
-- UNION ALL в YQL сопоставляет колонки по ИМЕНАМ, а не по позиции, и одинаковые
-- имена с разными типами он не сводит сам. Поэтому обе стороны приводим к
-- одному типу явно, а не надеемся на вывод типов.
--
-- Общий знаменатель для dialog — Yson: структурированный список сериализуется
-- в него без потерь, а правая колонка уже Yson. Для instruct — String: Utf8
-- кастуется в String всегда, обратный каст может не пройти.
--
-- ВАЖНО ДЛЯ СЛЕДУЮЩИХ ШАГОВ: после склейки dialog везде Yson, а не список
-- структур. Там, где раньше писали Yson::SerializeJson(Yson::From(t.dialog)),
-- теперь нужно Yson::SerializeJson(t.dialog) — колонка и так Yson,
-- второй раз заворачивать её не надо (см. pairwise_input.sql).

$all = (
    -- левая: dialog структурой, instruct в Utf8
    SELECT
        CAST(t.answer_1 AS String)            AS answer_1,
        CAST(t.answer_2 AS String)            AS answer_2,
        CAST(t.answer_source_1 AS String)     AS answer_source_1,
        CAST(t.answer_source_2 AS String)     AS answer_source_2,
        CAST(t.comment AS String)             AS comment,
        Yson::Serialize(Yson::From(t.dialog)) AS dialog,
        CAST(t.family_1 AS Utf8)              AS family_1,
        CAST(t.family_2 AS Utf8)              AS family_2,
        CAST(t.instruct AS String)            AS instruct,
        CAST(t.instruct_id AS String)         AS instruct_id,
        t.meta                                AS meta,
        CAST(t.promt AS String)               AS promt,
        CAST(t.real_instruct_id AS String)    AS real_instruct_id,
        CAST(t.winner AS String)              AS winner,
        -- откуда строка: пригодится, если склейку придётся разбирать обратно
        'input1'                              AS source_table
    FROM $input1 AS t

    UNION ALL

    -- правая: dialog уже Yson, приводить нечего
    SELECT
        CAST(t.answer_1 AS String)            AS answer_1,
        CAST(t.answer_2 AS String)            AS answer_2,
        CAST(t.answer_source_1 AS String)     AS answer_source_1,
        CAST(t.answer_source_2 AS String)     AS answer_source_2,
        CAST(t.comment AS String)             AS comment,
        t.dialog                              AS dialog,
        CAST(t.family_1 AS Utf8)              AS family_1,
        CAST(t.family_2 AS Utf8)              AS family_2,
        CAST(t.instruct AS String)            AS instruct,
        CAST(t.instruct_id AS String)         AS instruct_id,
        t.meta                                AS meta,
        CAST(t.promt AS String)               AS promt,
        CAST(t.real_instruct_id AS String)    AS real_instruct_id,
        CAST(t.winner AS String)              AS winner,
        'input2'                              AS source_table
    FROM $input2 AS t
);

INSERT INTO $output1 WITH TRUNCATE
SELECT *
FROM $all;

-- $output2 объявлен, но не пишется: склейка одна, второй таблице тут взяться
-- неоткуда. Если граф требует, чтобы вторая выходная таблица существовала,
-- раскомментируй — положит те же строки, чтобы шаг не падал на отсутствии
-- таблицы. Скажи, что должно быть во второй, если нужно что-то осмысленное.
--
-- INSERT INTO $output2 WITH TRUNCATE
-- SELECT * FROM $all;
