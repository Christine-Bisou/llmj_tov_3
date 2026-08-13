PRAGMA yt.InferSchema = "100";
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA yson.DisableStrict;
PRAGMA Yson.AutoConvert;
PRAGMA SimpleColumns;

DECLARE $input1 AS String;
DECLARE $output1 AS String;   -- диалоги
DECLARE $output2 AS String;   -- ответы первой модели
DECLARE $output3 AS String;   -- ответы второй модели

$script = @@#py
import json
from yql.typing import *


def trim_dialog_to_user(dialog_json: Optional[Utf8]) -> Optional[Utf8]:
    """Обрезает хвост диалога так, чтобы последняя реплика была от пользователя.

    Оценивается ответ модели на последний запрос пользователя, поэтому реплики
    ассистента в конце — это уже готовый ответ, который джадж видеть не должен.
    Возвращает None, если реплик пользователя в диалоге нет вообще: такая строка
    для разметки бесполезна и отфильтровывается целиком."""
    try:
        dialog = json.loads(dialog_json) if dialog_json else []
    except Exception:
        return None
    if not isinstance(dialog, list):
        return None

    while dialog:
        last = dialog[-1]
        role = last.get('role') if isinstance(last, dict) else None
        if str(role or '') == 'user':
            break
        dialog.pop()

    if not dialog:
        return None
    return json.dumps(dialog, ensure_ascii=False)
@@;

$trim_dialog_to_user = Python3::trim_dialog_to_user($script);

$src = (
    SELECT
        CAST(instruct_id AS String)        AS instruct_id,
        -- диалог хранится списком структур; Yson::From + SerializeJson даёт
        -- обычный JSON, с которым работает питоновская udf
        $trim_dialog_to_user(
            Yson::SerializeJson(Yson::From(dialog))
        )                                  AS dialog_json,
        CAST(answer_1 AS Utf8)             AS answer_1,
        CAST(answer_2 AS Utf8)             AS answer_2,
        CAST(answer_source_1 AS String)    AS answer_source_1,
        CAST(answer_source_2 AS String)    AS answer_source_2
    FROM $input1
);

-- строки без реплик пользователя выкидываем из всех трёх выходов сразу,
-- иначе таблицы ответов разъедутся с таблицей диалогов
$src_ok = (
    SELECT * FROM $src WHERE dialog_json IS NOT NULL
);

INSERT INTO $output1 WITH TRUNCATE
SELECT instruct_id, Yson::ParseJson(SOME(dialog_json)) AS dialog
FROM $src_ok GROUP BY instruct_id ORDER BY instruct_id;

INSERT INTO $output2 WITH TRUNCATE
SELECT instruct_id, answer_1 AS answer, answer_source_1 AS answer_source
FROM $src_ok ORDER BY instruct_id;

INSERT INTO $output3 WITH TRUNCATE
SELECT instruct_id, answer_2 AS answer, answer_source_2 AS answer_source
FROM $src_ok ORDER BY instruct_id;
