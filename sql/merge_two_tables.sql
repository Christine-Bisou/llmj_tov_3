PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.UseNativeYtTypes;
PRAGMA yt.InferSchema = '100';

DECLARE $input1 AS String;   -- широкая таблица: + comment, family_1/2, instruct, meta, promt; dialog = List<Struct<content, role>>
DECLARE $input2 AS String;   -- узкая таблица: только общие колонки; dialog = Yson
DECLARE $output1 AS String;  -- объединённые строки
DECLARE $output2 AS String;  -- сводка: сколько строк пришло из какой таблицы

-- true: при совпадении instruct_id оставить строку из первой таблицы
$dedup = false;

-- Схемы расходятся в двух местах, поэтому UNION ALL напрямую не собирается:
--   1) dialog: List<Struct<content:Utf8, role:Utf8>> против Yson — общего типа нет;
--   2) во второй таблице нет comment / family_1 / family_2 / instruct / meta / promt.
--
-- Приводим dialog к Yson (а не наоборот): Yson::From ничего не теряет, тогда как
-- обратная конвертация обрезала бы мультимодальный content — в нём список частей
-- с картинками, а не только строка. Дальше по пайплайну dialog всё равно уходит
-- в Yson::SerializeJson(Yson::From(...)), так что читателям правка не видна.

$from_1 = (
    SELECT
        answer_1,
        answer_2,
        answer_source_1,
        answer_source_2,
        comment,
        Yson::From(dialog)  AS dialog,
        family_1,
        family_2,
        instruct,
        instruct_id,
        meta,
        promt,
        real_instruct_id,
        winner,
        'input1'            AS source_table,
        1                   AS source_priority
    FROM $input1
);

$from_2 = (
    SELECT
        answer_1,
        answer_2,
        answer_source_1,
        answer_source_2,
        Nothing(ParseType('String?'))  AS comment,
        dialog,
        Nothing(ParseType('String?'))  AS family_1,
        Nothing(ParseType('String?'))  AS family_2,
        Nothing(ParseType('Utf8?'))    AS instruct,
        instruct_id,
        Nothing(ParseType('Yson?'))    AS meta,
        Nothing(ParseType('String?'))  AS promt,
        real_instruct_id,
        winner,
        'input2'                       AS source_table,
        2                              AS source_priority
    FROM $input2
);

$merged = (
    SELECT * FROM $from_1
    UNION ALL
    SELECT * FROM $from_2
);

$ranked = (
    SELECT
        m.*,
        ROW_NUMBER() OVER (PARTITION BY instruct_id ORDER BY source_priority) AS rn
    FROM $merged AS m
);

INSERT INTO $output1 WITH TRUNCATE
SELECT r.* WITHOUT r.rn, r.source_priority
FROM $ranked AS r
-- пустой instruct_id не склеиваем: иначе все такие строки схлопнутся в одну
WHERE NOT $dedup OR rn = 1 OR instruct_id IS NULL;

INSERT INTO $output2 WITH TRUNCATE
SELECT
    source_table,
    COUNT(*)                                        AS cnt,
    COUNT(DISTINCT instruct_id)                     AS uniq_instruct_id,
    AVG(IF(rn > 1, 1.0, 0.0))                       AS dup_share  -- доля строк, которые уберёт $dedup
FROM $ranked
GROUP BY source_table
ORDER BY source_table;
