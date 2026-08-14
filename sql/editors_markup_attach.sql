DECLARE $input1 AS String;  -- Изначальная таблица
DECLARE $input2 AS String;  -- Выход merge: input-поля + agg_tov_markup / raw_tov_markup
DECLARE $output1 AS String; -- Изначальная таблица + разметка и разметочные колонки
DECLARE $output2 AS String; -- Изначальная таблица + только словари разметки

PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

-- Джойн один на оба выхода, чтобы условие не разъезжалось между ними.
-- Ключ — instruct_id и rownum: rownum пронумеровывает строки корзины, так что
-- пара однозначно указывает на строку. Раньше вторым полем шло побайтовое
-- сравнение сериализованных answers — тяжёлое и хрупкое: любая пересборка
-- этого поля по дороге молча обнуляла бы джойн.
$joined = (
    SELECT
        orig.*,
        -- Разметочные колонки merge берём наравне со словарями: доставать их
        -- разбором Yson ради фильтра или сортировки незачем.
        tov.rownum AS rownum,
        tov.real_source_A AS real_source_A,
        tov.real_source_B AS real_source_B,
        tov.agg_tov_markup AS agg_tov_markup,
        tov.raw_tov_markup AS raw_tov_markup
    FROM $input2 AS tov
    INNER JOIN $input1 AS orig
    ON (
        Yson::LookupString(CAST(tov.input_meta AS Yson), 'instruct_id') = Yson::LookupString(CAST(orig.input_meta AS Yson), 'instruct_id')
        AND tov.rownum = Yson::LookupInt64(CAST(orig.input_meta AS Yson), 'rownum')
    )
);

INSERT INTO $output1 WITH TRUNCATE
SELECT *
FROM $joined;

-- Исходная таблица как есть плюс два словаря разметки, без разметочных
-- колонок: тем, кто ждёт прежнюю схему, лишние поля не нужны.
INSERT INTO $output2 WITH TRUNCATE
SELECT *
WITHOUT rownum, real_source_A, real_source_B
FROM $joined;
