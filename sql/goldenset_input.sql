-- Вход для разметки из одной таблицы-голденсета.
-- В отличие от парного варианта (двух источников ответов) здесь ответ ровно один
-- (right_answer), поэтому он дублируется в answer_1 и answer_2: формат разметки
-- всегда ждёт пару. Ключ склейки — instruct_id.

PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA yt.UseNativeYtTypes;

DECLARE $input AS String;
DECLARE $output1 AS String;  -- оригинал входа
DECLARE $output2 AS String;  -- сконвертированный вход для разметки

$input_ =
  SELECT
    target_markup,
    generator_dialog_json,
    right_answer,
    right_final_content_sources_json,
    session_id
  FROM $input;

$t =
  SELECT
    t.target_markup AS target_markup,
    t.generator_dialog_json.messages AS dialog,
    t.generator_dialog_json.meta AS meta,
    t.generator_dialog_json AS generator_dialog_json,
    t.session_id AS session_id,
    -- хэш строки: session_id один на диалог, но в поде может быть несколько
    -- срезов одной сессии, поэтому id считаем по всей строке, как в парном скрипте
    String::HexEncode(Digest::Sha256(ToBytes(Yson::SerializePretty(Yson::From(TableRow()))))) AS instruct_id,
    t.right_answer AS answer,
    Yson::ConvertToString(t.right_answer['neuro_alice_md_raw_wout_reasoning']) AS answer_text,
    t.right_final_content_sources_json AS final_content_sources_json,
  FROM $input_ AS t;

-- Оригинал входа: один и тот же ответ разложен в обе колонки
INSERT INTO $output1
SELECT
  instruct_id,
  session_id,
  target_markup,
  generator_dialog_json,
  final_content_sources_json AS final_content_sources_json_1,
  answer AS answer_1,
  final_content_sources_json AS final_content_sources_json_2,
  answer AS answer_2
FROM $t;

-- Сконвертированный вход для разметки
INSERT INTO $output2
SELECT
  instruct_id,
  dialog,
  meta,
  answer_text AS answer_1,
  'gs' AS answer_source_1,
  answer_text AS answer_2,
  'gs' AS answer_source_2
FROM $t;
