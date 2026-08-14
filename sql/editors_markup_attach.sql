DECLARE $input1 AS String;  -- Изначальная таблица
DECLARE $input2 AS String;  -- Выход merge: input-поля + agg_tov_markup / raw_tov_markup
DECLARE $output1 AS String; -- Изначальная таблица + словари разметки
DECLARE $output2 AS String; -- Только два словаря разметки

PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

-- Джойн один на оба выхода, чтобы условие не разъезжалось между ними.
-- Ключ — instruct_id и rownum: rownum пронумеровывает строки корзины, так что
-- пара однозначно указывает на строку. Оба поля берутся из input_meta с обеих
-- сторон — merge отдельными колонками их больше не отдаёт. Раньше вторым полем
-- шло побайтовое сравнение сериализованных answers: тяжёлое и хрупкое, любая
-- пересборка этого поля по дороге молча обнуляла бы джойн.
$joined = (
    SELECT
        orig.*,
        tov.agg_tov_markup AS agg_tov_markup,
        tov.raw_tov_markup AS raw_tov_markup
    FROM $input2 AS tov
    INNER JOIN $input1 AS orig
    ON (
        Yson::LookupString(CAST(tov.input_meta AS Yson), 'instruct_id') = Yson::LookupString(CAST(orig.input_meta AS Yson), 'instruct_id')
        AND Yson::LookupInt64(CAST(tov.input_meta AS Yson), 'rownum') = Yson::LookupInt64(CAST(orig.input_meta AS Yson), 'rownum')
    )
);

INSERT INTO $output1 WITH TRUNCATE
SELECT *
FROM $joined;

-- Только разметка, без исходных колонок: две колонки и ничего больше.
INSERT INTO $output2 WITH TRUNCATE
SELECT
    j.agg_tov_markup AS agg_tov_markup,
    j.raw_tov_markup AS raw_tov_markup
FROM $joined AS j;
