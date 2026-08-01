PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $tables_list AS List<String>;
DECLARE $out_table AS String;

$template = cast(FileContent("prompt_template.txt") as Utf8);

-- Колонки с ответами приезжают как Optional<Yson>: при InferSchema = '1' схема
-- выводится по первым строкам, и всё, что в неё не попало, остаётся yson-узлом.
-- Прямого каста Yson -> Utf8 в YQL нет (Cannot cast type Optional<Yson> into
-- Utf8), поэтому сначала достаём строку из узла, а уже её приводим к Utf8.
-- Если колонка окажется обычной String/Utf8, ConvertToString с AutoConvert
-- отработает так же — хелпер безопасен при любой схеме.
$as_utf8 = ($x) -> {
    RETURN CAST(Yson::ConvertToString($x) AS Utf8);
};

$script = @@#py
import re
import json
import base64
import urllib.request
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


def _image_to_base64(url):
    with urllib.request.urlopen(url, timeout=20) as resp:
        return base64.b64encode(resp.read()).decode('utf-8')


def _extract_text_and_images(content):
    """
    content может быть строкой (старый формат) или списком блоков
    {type: text|image_url, ...} (новый формат).
    Возвращает (text_with_markers, [image_urls]).
    """
    if content is None:
        return '', []
    if isinstance(content, str):
        return content, []
    if not isinstance(content, list):
        return str(content), []

    parts, images = [], []
    for item in content:
        if not isinstance(item, dict):
            continue
        item_type = item.get('type')
        if item_type == 'text':
            parts.append(str(item.get('text') or ''))
        elif item_type == 'image_url':
            img = item.get('image_url')
            url = ''
            if isinstance(img, dict):
                url = str(img.get('url') or '')
            elif isinstance(img, str):
                url = img
            if url:
                images.append(url)
                parts.append('[картинка]')
    return ' '.join(p for p in parts if p).strip(), images


def replace_alice(text: Optional[Utf8]) -> Optional[Utf8]:
    return _replace_alice(text)


def build_judge_input(
    dialog_json: Optional[Utf8],
    template: Optional[Utf8],
    answer_1: Optional[Utf8],
    answer_2: Optional[Utf8],
) -> Optional[Utf8]:
    MAX_MESSAGES = 5

    try:
        dialog = json.loads(dialog_json) if dialog_json else []
    except Exception:
        dialog = []
    if not isinstance(dialog, list):
        dialog = []

    if len(dialog) > MAX_MESSAGES:
        dialog = dialog[-MAX_MESSAGES:]

    dialog_lines = []
    image_urls = []
    for msg in dialog:
        if not isinstance(msg, dict):
            continue
        role = msg.get('role', 'user')
        text, msg_images = _extract_text_and_images(msg.get('content'))
        text = _replace_alice(text)
        prefix = 'Пользователь: ' if role == 'user' else 'Ассистент: '
        dialog_lines.append(prefix + text)
        image_urls.extend(msg_images)

    context_with_query = '\n\n'.join(dialog_lines)
    rendered = Template(str(template or '')).render(
        context_with_query=context_with_query,
        model_1_answer=_replace_alice(answer_1),
        model_2_answer=_replace_alice(answer_2),
    )

    if not image_urls:
        out = [{'role': 'user', 'content': rendered}]
        return json.dumps(out, ensure_ascii=False)

    content = []
    for url in image_urls:
        if url.startswith('data:'):
            data_url = url
        else:
            try:
                b64 = _image_to_base64(url)
            except Exception:
                continue
            data_url = 'data:image/jpeg;base64,' + b64
        content.append({
            'type': 'image_url',
            'image_url': {'url': data_url, 'detail': 'auto'},
        })
    content.append({'type': 'text', 'text': rendered})
    out = [{'role': 'user', 'content': content}]
    return json.dumps(out, ensure_ascii=False)
@@;

$build_judge_input = Python3::build_judge_input($script);

INSERT INTO $out_table
SELECT
  t.*,
  Yson::ParseJson(
    $build_judge_input(
      Yson::SerializeJson(Yson::From(${global.dialog_column})),
      $template,
      $as_utf8(${global.answer_1_column}),
      $as_utf8(${global.answer_2_column})
    )
  ) AS infer_dialog
  without if exists t.tov_prompt, t._other, t.infer_dialog
FROM Each($tables_list) as t;
