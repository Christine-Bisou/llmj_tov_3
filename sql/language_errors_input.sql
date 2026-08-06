PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $tables_list AS List<String>;
DECLARE $out_table AS String;

$template = cast(FileContent("prompt_template.txt") as Utf8);

-- Корректору подаются только два ответа: ни диалога, ни картинок в шаблоне нет.
-- Поэтому здесь нет ни сборки контекста, ни выкачивания изображений в base64 —
-- content всегда одна текстовая строка.
$script = @@#py
import re
import json
from yql.typing import *
from jinja2 import Template


_ALICE_PATTERN = re.compile(
    r'(?i)\b(?:алис[аеуоы]?|алисо[йю]|алисочк[аеиу]|алисоньк[аеиу]|алисик|'
    r'алиск(?:а|и|е|у|ой|ою|ам|ами|ах)?|алисок|alice)\b'
)


def _alice_word(word):
    lw = word.lower()
    if lw == 'алиса': res = 'ева'
    elif lw == 'алисы': res = 'евы'
    elif lw == 'алисе': res = 'еве'
    elif lw == 'алису': res = 'еву'
    elif lw == 'алисой': res = 'евой'
    elif lw == 'алисою': res = 'евою'
    elif lw == 'алис': res = 'ева'
    elif lw.startswith('алисочк'): res = lw.replace('алисочк', 'евочк')
    elif lw.startswith('алисоньк'): res = lw.replace('алисоньк', 'евоньк')
    elif lw.startswith('алисик'): res = lw.replace('алисик', 'евик')
    elif lw == 'алисок': res = 'евок'
    elif lw.startswith('алиск'): res = lw.replace('алиск', 'евк')
    elif lw == 'alice': res = 'eva'
    else: res = 'ева'

    if word.isupper(): return res.upper()
    if word.istitle(): return res.capitalize()
    return res


def _replace_alice(text):
    if not text:
        return ''
    return _ALICE_PATTERN.sub(lambda m: _alice_word(m.group(0)), str(text))


def build_judge_input(
    template: Optional[Utf8],
    answer_1: Optional[Utf8],
    answer_2: Optional[Utf8],
) -> Optional[Utf8]:
    rendered = Template(str(template or '')).render(
        model_1_answer=_replace_alice(answer_1),
        model_2_answer=_replace_alice(answer_2),
    )
    out = [{'role': 'user', 'content': rendered}]
    return json.dumps(out, ensure_ascii=False)
@@;

$build_judge_input = Python3::build_judge_input($script);

INSERT INTO $out_table
SELECT
  t.*,
  Yson::ParseJson(
    $build_judge_input(
      $template,
      cast(${global.answer_1_column} as Utf8),
      cast(${global.answer_2_column} as Utf8)
    )
  ) AS infer_dialog
  without if exists t.tov_prompt, t._other, t.infer_dialog
FROM Each($tables_list) as t;
