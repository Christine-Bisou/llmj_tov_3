PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;
DECLARE $output1 AS String;

-- берём все строки, где хотя бы одна из моделей пары — VLM
INSERT INTO $output1 WITH TRUNCATE
SELECT t.*
FROM $input1 AS t
WHERE CAST(t.family_1 AS String) == 'VLM'
   OR CAST(t.family_2 AS String) == 'VLM';
