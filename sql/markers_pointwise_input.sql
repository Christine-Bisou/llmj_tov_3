PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $tables_list AS List<String>;
DECLARE $out_table AS String;

-- Поинтвайзный первый этап: в промт уходит РОВНО ОДИН ответ.
-- Поэтому из каждой исходной строки делаем две: answer_slot = 1 (answer_1)
-- и answer_slot = 2 (answer_2). Инфер гоняется один раз по колонке
-- infer_dialog, дальше markers_pointwise_collapse.sql схлопывает пару обратно
-- в одну строку с ext_markers_1 / ext_markers_2.
--
-- prompt_template.txt — это prompts/tov_binary_markers_pointwise.md
-- (одна плейсхолдер-переменная {{model_answer}} вместо двух).
$template = cast(FileContent("prompt_template.txt") as Utf8);

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


def build_pointwise_input(
    dialog_json: Optional[Utf8],
    template: Optional[Utf8],
    answer: Optional[Utf8],
) -> Optional[Utf8]:
    """Собирает вход джаджа для ОДНОГО ответа.
    Второй ответ пары сюда не попадает намеренно: оценка должна быть
    абсолютной, без опоры на альтернативу и без позиционного эффекта."""
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
        model_answer=_replace_alice(answer),
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

$build_pointwise_input = Python3::build_pointwise_input($script);

INSERT INTO $out_table WITH TRUNCATE
SELECT
  Yson::ParseJson(
    $build_pointwise_input(
      Yson::SerializeJson(Yson::From(s.${global.dialog_column})),
      $template,
      IF(
        s.answer_slot = 1,
        cast(s.${global.answer_1_column} as Utf8),
        cast(s.${global.answer_2_column} as Utf8)
      )
    )
  ) AS infer_dialog,

  -- answer_slot приезжает уже скаляром из FLATTEN и уходит в вывод внутри s.*
  -- WITHOUT обязан быть последним элементом списка, иначе YQL ругается
  s.* WITHOUT IF EXISTS s.tov_prompt, s._other, s.infer_dialog
FROM (
  SELECT t.*, AsList(1, 2) AS answer_slot
  FROM Each($tables_list) AS t
) AS s
FLATTEN LIST BY s.answer_slot;
