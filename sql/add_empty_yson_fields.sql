DECLARE $input1 AS String;
DECLARE $output1 AS String;

PRAGMA yt.InferSchema = "100";
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA yson.DisableStrict;
PRAGMA Yson.AutoConvert;
PRAGMA SimpleColumns;

$empty = Yson::ParseJson("{}");

INSERT INTO $output1 WITH TRUNCATE
SELECT
    t.*,
    $empty AS answers,
    $empty AS input_final_messages,
    $empty AS input_meta,
    $empty AS input_render_data,
    $empty AS pointwise_a,
    $empty AS pointwise_b
FROM $input1 AS t;
