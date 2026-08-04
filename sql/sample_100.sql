PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;
DECLARE $output1 AS String;

-- Случайные 100 строк для просмотра глазами.
--
-- RandomNumber(TableRow()) — аргумент обязателен: без него YQL посчитает
-- вызов константой, вычислит один раз на всю таблицу и порядок не изменится.
-- Каждый запуск даёт новую выборку. Если нужна воспроизводимая — замени
-- сортировку на Digest::CityHash(CAST(instruct_id AS String)): тот же вход
-- будет всегда давать тот же семпл.
--
-- Сортировка идёт по всей таблице: на очень больших входах это дорого.
-- Тогда сначала обрежь вход (WHERE / TABLESAMPLE BERNOULLI), потом сортируй.

$sample_size = 100;

INSERT INTO $output1 WITH TRUNCATE
SELECT t.*
FROM $input1 AS t
ORDER BY RandomNumber(TableRow())
LIMIT $sample_size;
